#include "helper_math.h"
#include <cassert>
#include <type_traits>
#include "celllist.h"

__device__ __forceinline__ float3 readCoosFromAll4(const float4* xyzouvwo, int pid)
{
	const float4 tmp = xyzouvwo[2*pid];

	return make_float3(tmp.x, tmp.y, tmp.z);
}

__device__ __forceinline__ void readAll4(const float4* xyzouvwo, int pid, float3& coo, float3& vel)
{
	const float4 tmp1 = xyzouvwo[pid*2];
	const float4 tmp2 = xyzouvwo[pid*2+1];

	coo = make_float3(tmp1.x, tmp1.y, tmp1.z);
	vel = make_float3(tmp2.x, tmp2.y, tmp2.z);
}

__device__ __forceinline__ float sqr(float x)
{
	return x*x;
}

template<typename Ta, typename Tb>
__device__ __forceinline__ float distance2(const Ta a, const Tb b)
{
	return sqr(a.x - b.x) + sqr(a.y - b.y) + sqr(a.z - b.z);
}

//__launch_bounds__(128, 16)
template<typename Interaction>
__global__ void computeSelfInteractions(const float4 * __restrict__ xyzouvwo, float* axayaz, const int * __restrict__ cellsstart,
		int3 ncells, float3 domainStart, int ncells_1, int np, Interaction interaction)
{
	const int dstId = blockIdx.x*blockDim.x + threadIdx.x;
	if (dstId >= np) return;

	float3 dstCoo, dstVel;
	float3 dstAcc = make_float3(0.0f);
	readAll4(xyzouvwo, dstId, dstCoo, dstVel);

	const int cellX0 = getCellIdAlongAxis(dstCoo.x, domainStart.x, ncells.x, 1.0f);
	const int cellY0 = getCellIdAlongAxis(dstCoo.y, domainStart.y, ncells.y, 1.0f);
	const int cellZ0 = getCellIdAlongAxis(dstCoo.z, domainStart.z, ncells.z, 1.0f);

#pragma unroll
	for (int cellY = cellY0-1; cellY <= cellY0; cellY++)
#pragma unroll
		for (int cellZ = cellZ0-1; cellZ <= cellZ0+1; cellZ++)
		{
			if ( !(cellY >= 0 && cellY < ncells.y && cellZ >= 0 && cellZ < ncells.z) ) continue;
			if (cellY == cellY0 && cellZ > cellZ0) continue;

			const int midCellId = (cellZ*ncells.y + cellY)*ncells.x + cellX0;
			int rowStart  = max(midCellId-1, 0);
			int rowEnd    = min(midCellId+2, ncells_1);
			if ( cellY == cellY0 && cellZ == cellZ0 ) rowEnd = midCellId + 1; // this row is already partly covered

			const int pstart = cellsstart[rowStart];
			const int pend   = cellsstart[rowEnd];

			for (int srcId = pstart; srcId < pend; srcId ++)
			{
				const float3 srcCoo = readCoosFromAll4(xyzouvwo, srcId);

				bool interacting = distance2(srcCoo, dstCoo) < 1.00f;
				if (dstId <= srcId && cellY == cellY0 && cellZ == cellZ0) interacting = false;

				if (interacting)
				{
					float3 srcCoo, srcVel;
					readAll4(xyzouvwo, srcId, srcCoo, srcVel);

					float3 frc = interaction(dstCoo, dstVel, dstId, srcCoo, srcVel, srcId);

					dstAcc += frc;

					float* dest = axayaz + srcId*4;
					atomicAdd(dest,     -frc.x);
					atomicAdd(dest + 1, -frc.y);
					atomicAdd(dest + 2, -frc.z);
				}
			}
		}

	float* dest = axayaz + dstId*4;
	atomicAdd(dest,     dstAcc.x);
	atomicAdd(dest + 1, dstAcc.y);
	atomicAdd(dest + 2, dstAcc.z);
}


template<bool NeedDstAcc, bool NeedSrcAcc, typename Interaction>
__global__ void computeHaloInteractions(
		const float4 * __restrict__ dstData, float* dstAccs,
		const float4 * __restrict__ srcData, float* srcAccs,
		const int * __restrict__ cellsstart, int3 ncells, float3 domainStart, int ncells_1, int ndst, Interaction interaction)
{
	static_assert(NeedDstAcc || NeedSrcAcc, "External interactions should return at least some accelerations");

	const int dstId = blockIdx.x*blockDim.x + threadIdx.x;
	if (dstId >= ndst) return;

	float3 dstCoo, dstVel;
	float3 dstAcc = make_float3(0.0f);
	readAll4(dstData, dstId, dstCoo, dstVel);

	const int cellX0 = getCellIdAlongAxis<false>(dstCoo.x, domainStart.x, ncells.x, 1.0f);
	const int cellY0 = getCellIdAlongAxis<false>(dstCoo.y, domainStart.y, ncells.y, 1.0f);
	const int cellZ0 = getCellIdAlongAxis<false>(dstCoo.z, domainStart.z, ncells.z, 1.0f);

	int validCells[9];
	int valid = 0;

#pragma unroll 3
	for (int cellX = cellX0-1; cellX <= cellX0+1; cellX++)
#pragma unroll 3
		for (int cellY = cellY0-1; cellY <= cellY0+1; cellY++)
#pragma unroll 3
			for (int cellZ = cellZ0-1; cellZ <= cellZ0+1; cellZ++)
				if ( (cellX >= 0 && cellX < ncells.x && cellY >= 0 && cellY < ncells.y && cellZ >= 0 && cellZ < ncells.z) )
					validCells[valid++] = (cellZ*ncells.y + cellY)*ncells.x + cellX;

#pragma unroll 9
	for (int vcell=0; vcell < valid; vcell++)
	{
		const int pstart = cellsstart[validCells[vcell]];
		const int pend   = cellsstart[validCells[vcell]+1];

		for (int srcId = pstart; srcId < pend; srcId ++)
		{
			const float3 srcCoo = readCoosFromAll4(srcData, srcId);

			bool interacting = distance2(srcCoo, dstCoo) < 1.0f;

			if (interacting)
			{
				float3 srcCoo, srcVel;
				readAll4(srcData, srcId, srcCoo, srcVel);

				float3 frc = interaction(dstCoo, dstVel, dstId, srcCoo, srcVel, srcId);

				if (NeedDstAcc)
					dstAcc += frc;
				if (NeedSrcAcc)
				{
					float* dest = srcAccs + srcId*4;

					atomicAdd(dest,     -frc.x);
					atomicAdd(dest + 1, -frc.y);
					atomicAdd(dest + 2, -frc.z);
				}
			}
		}
	}

	if (NeedDstAcc)
	{
		float* dest = dstAccs + dstId*4;
		dest[0] += dstAcc.x;
		dest[1] += dstAcc.y;
		dest[2] += dstAcc.z;
	}
}


template<bool NeedDstAcc, bool NeedSrcAcc, typename Interaction>
__global__ void computeExternalInteractions(
		const float4 * __restrict__ dstData, float* dstAccs,
		const float4 * __restrict__ srcData, float* srcAccs,
		const int * __restrict__ cellsstart, int3 ncells, float3 domainStart, int ncells_1, int ndst, Interaction interaction)
{
	static_assert(NeedDstAcc || NeedSrcAcc, "External interactions should return at least some accelerations");

	const int dstId = blockIdx.x*blockDim.x + threadIdx.x;
	if (dstId >= ndst) return;

	float3 dstCoo, dstVel;
	float3 dstAcc = make_float3(0.0f);
	readAll4(dstData, dstId, dstCoo, dstVel);

	const int cellX0 = getCellIdAlongAxis<false>(dstCoo.x, domainStart.x, ncells.x, 1.0f);
	const int cellY0 = getCellIdAlongAxis<false>(dstCoo.y, domainStart.y, ncells.y, 1.0f);
	const int cellZ0 = getCellIdAlongAxis<false>(dstCoo.z, domainStart.z, ncells.z, 1.0f);

#pragma unroll
	for (int cellY = cellY0-1; cellY <= cellY0+1; cellY++)
		for (int cellZ = cellZ0-1; cellZ <= cellZ0+1; cellZ++)
		{
			if ( !(cellY >= 0 && cellY < ncells.y && cellZ >= 0 && cellZ < ncells.z) ) continue;

			const int midCellId = (cellZ*ncells.y + cellY)*ncells.x + cellX0;
			int rowStart  = max(midCellId-1, 0);
			int rowEnd    = min(midCellId+2, ncells_1);

			const int pstart = cellsstart[rowStart];
			const int pend   = cellsstart[rowEnd];

			for (int srcId = pstart; srcId < pend; srcId ++)
			{
				const float3 srcCoo = readCoosFromAll4(srcData, srcId);

				bool interacting = distance2(srcCoo, dstCoo) < 1.0f;

				if (interacting)
				{
					float3 srcCoo, srcVel;
					readAll4(srcData, srcId, srcCoo, srcVel);

					float3 frc = interaction(dstCoo, dstVel, dstId, srcCoo, srcVel, srcId);

					if (NeedDstAcc)
						dstAcc += frc;
					if (NeedSrcAcc)
					{
						float* dest = srcAccs + srcId*4;

						atomicAdd(dest,     -frc.x);
						atomicAdd(dest + 1, -frc.y);
						atomicAdd(dest + 2, -frc.z);
					}
				}
			}
		}

	if (NeedDstAcc)
	{
		float* dest = dstAccs + dstId*4;
		dest[0] += dstAcc.x;
		dest[1] += dstAcc.y;
		dest[2] += dstAcc.z;
	}
}
