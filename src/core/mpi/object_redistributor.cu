#include "object_redistributor.h"
#include "exchange_helpers.h"

#include <core/utils/kernel_launch.h>
#include <core/pvs/particle_vector.h>
#include <core/pvs/object_vector.h>
#include <core/pvs/views/ov.h>
#include <core/pvs/extra_data/packers.h>
#include <core/logger.h>
#include <core/utils/cuda_common.h>

template<bool QUERY>
__global__ void getExitingObjects(const DomainInfo domain, OVview view, const ObjectPacker packer, BufferOffsetsSizesWrap dataWrap)
{
    const int objId = blockIdx.x;
    const int tid = threadIdx.x;

    if (objId >= view.nObjects) return;

    // Find to which buffer this object should go
    auto prop = view.comAndExtents[objId];
    int cx = 1, cy = 1, cz = 1;

    if (prop.com.x  < -0.5f*domain.localSize.x) cx = 0;
    if (prop.com.y  < -0.5f*domain.localSize.y) cy = 0;
    if (prop.com.z  < -0.5f*domain.localSize.z) cz = 0;

    if (prop.com.x >=  0.5f*domain.localSize.x) cx = 2;
    if (prop.com.y >=  0.5f*domain.localSize.y) cy = 2;
    if (prop.com.z >=  0.5f*domain.localSize.z) cz = 2;

    const int bufId = (cz*3 + cy)*3 + cx;

    __shared__ int shDstObjId;

    const float3 shift{ domain.localSize.x*(cx-1),
                        domain.localSize.y*(cy-1),
                        domain.localSize.z*(cz-1) };

    __syncthreads();
    if (tid == 0)
        shDstObjId = atomicAdd(dataWrap.sizes + bufId, 1);

    if (QUERY) {
        return;
    }
    else {
        __syncthreads();

        char* dstAddr = dataWrap.buffer + packer.totalPackedSize_byte * (dataWrap.offsets[bufId] + shDstObjId);

        for (int pid = tid; pid < view.objSize; pid += blockDim.x)
        {
            const int srcPid = objId * view.objSize + pid;
            packer.part.packShift(srcPid, dstAddr + pid*packer.part.packedSize_byte, -shift);
        }

        dstAddr += view.objSize * packer.part.packedSize_byte;
        if (tid == 0) packer.obj.packShift(objId, dstAddr, -shift);
    }
}

__global__ static void unpackObject(const char* from, const int startDstObjId, OVview view, ObjectPacker packer)
{
    const int objId = blockIdx.x;
    const int tid = threadIdx.x;

    const char* srcAddr = from + packer.totalPackedSize_byte * objId;

    for (int pid = tid; pid < view.objSize; pid += blockDim.x)
    {
        const int dstId = (startDstObjId+objId)*view.objSize + pid;
        packer.part.unpack(srcAddr + pid*packer.part.packedSize_byte, dstId);
    }

    srcAddr += view.objSize * packer.part.packedSize_byte;
    if (tid == 0) packer.obj.unpack(srcAddr, startDstObjId+objId);
}

//===============================================================================================
// Member functions
//===============================================================================================

bool ObjectRedistributor::needExchange(int id)
{
    return !objects[id]->redistValid;
}

void ObjectRedistributor::attach(ObjectVector* ov, float rc)
{
    objects.push_back(ov);
    ExchangeHelper* helper = new ExchangeHelper(ov->name);
    helpers.push_back(helper);
    info("The Object vector '%s' was attached", ov->name.c_str());
}


void ObjectRedistributor::prepareSizes(int id, cudaStream_t stream)
{
    auto ov  = objects[id];
    auto lov = ov->local();
    auto helper = helpers[id];

    ov->findExtentAndCOM(stream, ParticleVectorType::Local);

    OVview ovView(ov, ov->local());
    ObjectPacker packer(ov, ov->local(), stream);
    helper->setDatumSize(packer.totalPackedSize_byte);

    debug2("Counting exiting objects of '%s'", ov->name.c_str());
    const int nthreads = 256;

    // Prepare sizes
    helper->sendSizes.clear(stream);
    if (ovView.nObjects > 0)
    {
        SAFE_KERNEL_LAUNCH(
                getExitingObjects<true>,
                ovView.nObjects, nthreads, 0, stream,
                ov->domain, ovView, packer, helper->wrapSendData() );

        helper->makeSendOffsets_Dev2Dev(stream);
    }

    int nObjs = helper->sendSizes[13];
    debug2("%d objects of '%s' will leave", ovView.nObjects - nObjs, ov->name.c_str());

    // Early termination support
    if (nObjs == ovView.nObjects)
    {
        helper->sendSizes[13] = 0;
        helper->makeSendOffsets();
        helper->resizeSendBuf();
    }
}

void ObjectRedistributor::prepareData(int id, cudaStream_t stream)
{
    auto ov  = objects[id];
    auto lov = ov->local();
    auto helper = helpers[id];

    OVview ovView(ov, ov->local());
    ObjectPacker packer(ov, ov->local(), stream);
    helper->setDatumSize(packer.totalPackedSize_byte);

    const int nthreads = 256;
    int nObjs = helper->sendSizes[13];

    // Early termination - no redistribution
    if (helper->sendOffsets[27] == 0)
    {
        debug2("No objects of '%s' leaving, no need to rebuild the object vector", ov->name.c_str());
        return;
    }

    debug2("Downloading %d leaving objects of '%s'", ovView.nObjects - nObjs, ov->name.c_str());

    // Gather data
    helper->resizeSendBuf();
    helper->sendSizes.clearDevice(stream);
    SAFE_KERNEL_LAUNCH(
            getExitingObjects<false>,
            lov->nObjects, nthreads, 0, stream,
            ov->domain, ovView, packer, helper->wrapSendData() );


    // Unpack the central buffer into the object vector itself
    // Renew view and packer, as the ObjectVector may have resized
    lov->resize_anew(nObjs*ov->objSize);
    ovView = OVview(ov, ov->local());
    packer = ObjectPacker(ov, ov->local(), stream);

    SAFE_KERNEL_LAUNCH(
            unpackObject,
            nObjs, nthreads, 0, stream,
            helper->sendBuf.devPtr() + helper->sendOffsets[13] * packer.totalPackedSize_byte, 0, ovView, packer );


    // Finally need to compact the buffers
    // to get rid of the "self" part
    // TODO: remove this, own buffer should be last (performance penalty only, correctness is there)
    
    int copySize = (helper->sendOffsets[27]-helper->sendOffsets[14]) * helper->datumSize;
    temp.resize_anew(copySize);
    
    CUDA_Check( cudaMemcpyAsync( temp.devPtr(),
                                 helper->sendBuf.devPtr() + helper->sendOffsets[14]*helper->datumSize,
                                 copySize, cudaMemcpyDeviceToDevice, stream ) );
    
    CUDA_Check( cudaMemcpyAsync( helper->sendBuf.devPtr() + helper->sendOffsets[13]*helper->datumSize,
                                 temp.devPtr(),
                                 copySize, cudaMemcpyDeviceToDevice, stream ) );
                                 
    helper->sendSizes[13] = 0;
    helper->makeSendOffsets();
    helper->resizeSendBuf();

    // simple workaround when # of remaining >= # of leaving
//    if (helper->sendSizes[13] >= helper->sendOffsets[27]-helper->sendOffsets[14])
//    {
//        CUDA_Check( cudaMemcpyAsync( helper->sendBuf.devPtr() + helper->sendOffsets[13]*helper->datumSize,
//                                     helper->sendBuf.devPtr() + helper->sendOffsets[14]*helper->datumSize,
//                                     (helper->sendOffsets[27]-helper->sendOffsets[14]) * helper->datumSize,
//                                     cudaMemcpyDeviceToDevice, stream ) );
//
//        helper->sendSizes[13] = 0;
//        helper->makeSendOffsets();
//        helper->resizeSendBuf();
//    }
}

void ObjectRedistributor::combineAndUploadData(int id, cudaStream_t stream)
{
    auto ov = objects[id];
    auto helper = helpers[id];

    int oldNObjs = ov->local()->nObjects;
    int objSize = ov->objSize;

    int totalRecvd = helper->recvOffsets[helper->nBuffers];

    ov->local()->resize(ov->local()->size() + totalRecvd * objSize, stream);
    OVview ovView(ov, ov->local());
    ObjectPacker packer(ov, ov->local(), stream);

    const int nthreads = 64;
    SAFE_KERNEL_LAUNCH(
            unpackObject,
            totalRecvd, nthreads, 0, stream,
            helper->recvBuf.devPtr(), oldNObjs, ovView, packer );

    ov->redistValid = true;

    // Particles may have migrated, rebuild cell-lists
    if (totalRecvd > 0)
    {
        ov->cellListStamp++;
        ov->local()->comExtentValid = false;
    }
}



