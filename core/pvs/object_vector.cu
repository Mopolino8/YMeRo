#include "object_vector.h"

#include <core/utils/kernel_launch.h>
#include <core/utils/cuda_common.h>

__global__ void min_max_com(OVview ovView)
{
	const int gid = threadIdx.x + blockDim.x * blockIdx.x;
	const int objId = gid >> 5;
	const int tid = gid & 0x1f;
	if (objId >= ovView.nObjects) return;

	float3 mymin = make_float3( 1e+10f);
	float3 mymax = make_float3(-1e+10f);
	float3 mycom = make_float3(0);

#pragma unroll 3
	for (int i = tid; i < ovView.objSize; i += warpSize)
	{
		const int offset = (objId * ovView.objSize + i) * 2;

		const float3 coo = make_float3(ovView.particles[offset]);

		mymin = fminf(mymin, coo);
		mymax = fmaxf(mymax, coo);
		mycom += coo;
	}

	mycom = warpReduce( mycom, [] (float a, float b) { return a+b; } );
	mymin = warpReduce( mymin, [] (float a, float b) { return fmin(a, b); } );
	mymax = warpReduce( mymax, [] (float a, float b) { return fmax(a, b); } );

	if (tid == 0)
		ovView.comAndExtents[objId] = {mycom / ovView.objSize, mymin, mymax};
}

void ObjectVector::findExtentAndCOM(cudaStream_t stream, bool isLocal)
{
	auto lov = isLocal ? local() : halo();

	if (lov->comExtentValid)
	{
		debug("COM and extent computation for %s OV '%s' skipped",
				isLocal ? "local" : "halo", name.c_str());
		return;
	}

	debug("Computing COM and extent OV '%s' (%s)", name.c_str(), isLocal ? "local" : "halo");

	const int nthreads = 128;
	OVview ovView(this, lov);
	SAFE_KERNEL_LAUNCH(
			min_max_com,
			(ovView.nObjects*32 + nthreads-1)/nthreads, nthreads, 0, stream,
			ovView );
}