#include "velocity_control.h"
#include <plugins/simple_serializer.h>
#include <core/datatypes.h>
#include <core/pvs/particle_vector.h>
#include <core/pvs/views/pv.h>
#include <core/simulation.h>
#include <core/utils/cuda_common.h>
#include <core/utils/kernel_launch.h>

namespace velocity_control_kernels {

static __device__ bool is_inside(float3 r, float3 low, float3 high)
{
    return
        low.x <= r.x && r.x <= high.x &&
        low.y <= r.y && r.y <= high.y &&
        low.z <= r.z && r.z <= high.z;
}

__global__ void addForce(PVview view, DomainInfo domain, float3 low, float3 high, float3 force)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= view.size) return;

    Particle p;
    p.readCoordinate(view.particles, gid);
    float3 gr = domain.local2global(p.r);

    if (is_inside(gr, low, high))
        view.forces[gid] += make_float4(force, 0.0f);
}

__global__ void sumVelocity(PVview view, DomainInfo domain, float3 low, float3 high, float3 *totVel, int *nSamples)
{
    int gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= view.size) return;

    Particle p(view.particles, gid);
    float3 gr = domain.local2global(p.r);

    if (is_inside(gr, low, high))
        atomicAggInc(nSamples);
    else
        p.u = make_float3(0.0f);

    float3 u = warpReduce(p.u, [](float a, float b) { return a+b; });
    if (threadIdx.x % warpSize == 0 && dot(u, u) > 1e-8)
        atomicAdd(totVel, u);
}

}

void SimulationVelocityControl::setup(Simulation* sim, const MPI_Comm& comm, const MPI_Comm& interComm)
{
    SimulationPlugin::setup(sim, comm, interComm);

    pv = sim->getPVbyNameOrDie(pvName);
}

void SimulationVelocityControl::beforeForces(cudaStream_t stream)
{
    PVview view(pv, pv->local());
    const int nthreads = 128;

    SAFE_KERNEL_LAUNCH(
            velocity_control_kernels::addForce,
            getNblocks(view.size, nthreads), nthreads, 0, stream,
            view, pv->domain, low, high, force );
}

void SimulationVelocityControl::afterIntegration(cudaStream_t stream)
{
    if (currentTimeStep % sampleEvery != 0 || currentTimeStep == 0) return;

    debug2("Velocity control %s is sampling now", name.c_str());

    PVview pvView(pv, pv->local());
    const int nthreads = 128;
    long nSamples_loc, nSamples_tot = 0;
    double3 totVel_loc, totVel_tot = make_double3(0,0,0);  
    
    totVel.clearDevice(stream);
    nSamples.clearDevice(stream);

    SAFE_KERNEL_LAUNCH(
            velocity_control_kernels::sumVelocity,
            getNblocks(pvView.size, nthreads), nthreads, 0, stream,
            pvView, pv->domain, low, high, totVel.devPtr(), nSamples.devPtr());

    totVel.downloadFromDevice(stream, false);
    nSamples.downloadFromDevice(stream);

    nSamples_loc = nSamples[0];
    totVel_loc   = make_double3( totVel[0] );
    
    MPI_Check( MPI_Allreduce(&nSamples_loc, &nSamples_tot, 1, MPI_LONG,   MPI_SUM, comm) );
    MPI_Check( MPI_Allreduce(&totVel_loc,   &totVel_tot,   3, MPI_DOUBLE, MPI_SUM, comm) );

    currentVel = make_float3(totVel_tot / nSamples_tot);
    force = pid.update(targetVel - currentVel);
}

void SimulationVelocityControl::serializeAndSend(cudaStream_t stream)
{
    if (currentTimeStep % dumpEvery != 0 || currentTimeStep == 0) return;

    SimpleSerializer::serialize(sendBuffer, currentTime, currentTimeStep, currentVel, force);
    send(sendBuffer);
    info("haha");
}




PostprocessVelocityControl::PostprocessVelocityControl(std::string name, std::string filename) :
    PostprocessPlugin(name)
{
    fdump = fopen(filename.c_str(), "w");
    if (!fdump) die("Could not open file '%s'", filename.c_str());
    fprintf(fdump, "# time time_step velocity force\n");
}

PostprocessVelocityControl::~PostprocessVelocityControl()
{
    fclose(fdump);
}

void PostprocessVelocityControl::deserialize(MPI_Status& stat)
{
    int currentTimeStep;
    float currentTime;
    float3 vel, force;

    info("hoho");
    
    SimpleSerializer::deserialize(data, currentTime, currentTimeStep, vel, force);

    // if (rank == 0) {
        fprintf(fdump,
                "%g %d "
                "%g %g %g "
                "%g %g %g\n",
                currentTime, currentTimeStep,
                vel.x, vel.y, vel.z,
                force.x, force.y, force.z
                );
    // }
}