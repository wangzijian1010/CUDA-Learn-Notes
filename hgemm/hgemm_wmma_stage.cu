#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <cuda_fp8.h>
#include <mma.h>
#include <torch/types.h>
#include <torch/extension.h>
using namespace nvcuda;

#define WARP_SIZE 32
#define DEVICE_INLINE __device__ inline
#define HOST_DEVICE_INLINE __device__ __host__ inline
#define INT4(value) (reinterpret_cast<int4*>(&(value))[0])
#define FLOAT4(value) (reinterpret_cast<float4*>(&(value))[0])
#define HALF2(value) (reinterpret_cast<half2*>(&(value))[0])
#define BFLOAT2(value) (reinterpret_cast<__nv_bfloat162*>(&(value))[0])
#define LDST32BITS(value) (reinterpret_cast<half2*>(&(value))[0])
#define LDST64BITS(value) (reinterpret_cast<float2*>(&(value))[0])
#define LDST128BITS(value) (reinterpret_cast<float4*>(&(value))[0])
#define CP_ASYNC_COMMIT_GROUP() asm volatile("cp.async.commit_group;\n" ::)
#define CP_ASYNC_WAIT_ALL() asm volatile("cp.async.wait_all;\n" ::)
#define CP_ASYNC_WAIT_GROUP(n) asm volatile("cp.async.wait_group %0;\n" ::"n"(n))
// ca(cache all, L1 + L2): support 4, 8, 16 bytes, cg(cache global, L2): only support 16 bytes.
#define CP_ASYNC_CA(dst, src, bytes) asm volatile("cp.async.ca.shared.global.L2::128B [%0], [%1], %2;\n" ::"r"(dst), "l"(src), "n"(bytes))
#define CP_ASYNC_CG(dst, src, bytes) asm volatile("cp.async.cg.shared.global.L2::128B [%0], [%1], %2;\n" ::"r"(dst), "l"(src), "n"(bytes))
// Support A and B matrix with row-major inorder to compare with the kernels using CUDA Cores in
// hgemm.cu and hgemm_async.cu. 


HOST_DEVICE_INLINE 
int div_ceil(int a, int b) { return (a % b != 0) ? (a / b + 1) : (a / b); }

// stage2/3/4 (stage2=double buffers+copy async)
// 1. 当使用的shared memory超过48 KB时，需要使用dynamic shared 
// memory， 即extern __shared__ half smem[];这样声明一块动态
// 共享内存，调用kernel时 需要指定动态共享内存大小，且smem的寻址
// 方式需要按照一维数组来使用 2. 提高L2 Cache的局部性(Thread 
// Block Swizzle): https://zhuanlan.zhihu.com/p/555339335
template<const int WMMA_M=16, const int WMMA_N=16, const int WMMA_K=16, 
         const int WMMA_TILE_M=4, const int WMMA_TILE_N=2, 
         const int WARP_TILE_M=2, const int WARP_TILE_N=4,
         const int K_STAGE=2, const int OFFSET=0, 
         const bool BLOCK_SWIZZLE = false>
__global__ void hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_kernel(
  half* A, half* B, half* C, int M, int N, int K) {
  // 256 threads(8 warps) per block.
  // const int bx = blockIdx.x;
  // BLOCK_SWIZZLE 0/1 控制是否使用 block swizzle
  const int bx = ((int) BLOCK_SWIZZLE) * blockIdx.z * gridDim.x + blockIdx.x;
  const int by = blockIdx.y;
  const int NUM_K_TILES = div_ceil(K, WMMA_K);
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M; // 16x4*2=128
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N; // 16x2*4=128
  constexpr int BK = WMMA_K; // 16
  // s2: 2*128*(16+8)*2=12KB, 2*16*(128+8)*2=8.50KB,  ~21KB
  // s3: 3*128*(16+8)*2=18KB, 3*16*(128+8)*2=12.75KB, ~31KB
  // s4: 4*128*(16+8)*2=24KB, 4*16*(128+8)*2=17KB,    ~41KB
  __shared__ half s_a[K_STAGE][BM][BK+OFFSET], s_b[K_STAGE][BK][BN+OFFSET]; 
  constexpr int s_a_stage_offset = BM * (BK + OFFSET);
  constexpr int s_b_stage_offset = BK * (BN + OFFSET);
 
  // 要保证相同的warp下thread执行相同的指令
  const int tid = threadIdx.y * blockDim.x + threadIdx.x;
  const int warp_id = tid / WARP_SIZE; // tid >> 5; // 0~7 warp_id within block
  const int warp_m =  warp_id / 2; // warp_id >> 1; // 0,1,2,3
  const int warp_n = warp_id % 2; // 0,1
  
  // 先计算shared memory中的索引
  // tid和需要加载的smem s_a[BM][BK] 之间的索引关系 BM=128 BK=16 按行读取 A行主序
  // 对于s_a每行16个数据，每个线程读取8个，需要2个线程；总共128行，需要128x2刚好256线程
  int load_smem_a_m = tid / 2; // tid >> 1; // row 0~127
  int load_smem_a_k = (tid % 2 == 0) ? 0 : 8; // col 0,8
  // tid和需要加载的smem s_b[BK][BN] 之间的索引关系 BK=16 BN=128 按行读取 B行主序
  // 对于s_b每行128个数据，每个线程读8个数据，需要16个线程；总共16行，需要16x16=256个线程
  int load_smem_b_k = tid / 16; // tid >> 4; // row 0~15
  int load_smem_b_n =  (tid % 16) * 8; // ((tid & 0xF) << 3); // col 0,8,...,120
  // 再计算全局内存中的索引
  // 要加载到s_a中的元素对应到A全局内存中的行数 每个block负责出C中大小为BM*BN的块
  int load_gmem_a_m = by * BM + load_smem_a_m; // global row of a and c
  int load_gmem_b_n = bx * BN + load_smem_b_n; // global col of b and c

  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> 
  C_frag[WARP_TILE_M][WARP_TILE_N];
  
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      wmma::fill_fragment(C_frag[i][j], 0.0);
    }
  }

  // may avoid cvta overhead ? only cvta smem base ptr once for cp.async.
  uint32_t smem_a_base_ptr = __cvta_generic_to_shared(s_a);
  uint32_t smem_b_base_ptr = __cvta_generic_to_shared(s_b);

  #pragma unroll
  for (int k = 0; k < (K_STAGE - 1); ++k) { // 0, 1
    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 

    // uint32_t load_smem_a_ptr = __cvta_generic_to_shared(
    //   &s_a[k][load_smem_a_m][load_smem_a_k]);
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (k * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr, &A[load_gmem_a_addr], 16);

    // uint32_t load_smem_b_ptr = __cvta_generic_to_shared(
    //   &s_b[k][load_smem_b_k][load_smem_b_n]);
    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (k * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);

    CP_ASYNC_COMMIT_GROUP();
  }

  CP_ASYNC_WAIT_GROUP(K_STAGE-2); // s2->0, s3->1, s4->2
  __syncthreads(); 

  #pragma unroll
  for (int k = (K_STAGE - 1); k < NUM_K_TILES; k++) { 
    // s2/4 can use bitwise ops but s3 can not, so, we use mod
    // ops for all stages kernel. s2: (k + 1)&1, s4: (k + 1)&3
    // s3: (k + 1) % 3
    int smem_sel = (k + 1) % K_STAGE; // s3 k 2->0, k 3->1, k 4->2...
    int smem_sel_next = k % K_STAGE;  // s3 k 2->2, k 3->0, k 4->1...

    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 

    // load stage 2, k start from 2
    // uint32_t load_smem_a_ptr = __cvta_generic_to_shared(
    //   &s_a[smem_sel_next][load_smem_a_m][load_smem_a_k]);
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (smem_sel_next * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr, &A[load_gmem_a_addr], 16);

    // uint32_t load_smem_b_ptr = __cvta_generic_to_shared(
    //   &s_b[smem_sel_next][load_smem_b_k][load_smem_b_n]);
    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (smem_sel_next * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);
    CP_ASYNC_COMMIT_GROUP();

    wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> A_frag[WARP_TILE_M];
    wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> B_frag[WARP_TILE_N];
    
    // compute stage 0
    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
      const int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      wmma::load_matrix_sync(A_frag[i], &s_a[smem_sel][warp_smem_a_m][0], BK + OFFSET); 
    }

    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
      const int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      wmma::load_matrix_sync(B_frag[j], &s_b[smem_sel][0][warp_smem_b_n], BN + OFFSET);
    }

    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
      }
    }

    CP_ASYNC_WAIT_GROUP(K_STAGE-2);
    __syncthreads(); 
  }
  
  // make sure all memory issues ready.
  if ((K_STAGE - 2) > 0) {
    CP_ASYNC_WAIT_GROUP(0);
    __syncthreads(); 
  }
  // processing last (K_STAGE-1) k iters.
  {
    #pragma unroll
    for (int k = 0; k < (K_STAGE - 1); k++) {
      const int stage_sel = ((NUM_K_TILES - (K_STAGE - 1) + k) % K_STAGE);
      wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> A_frag[WARP_TILE_M];
      wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> B_frag[WARP_TILE_N];
    
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
        const int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
        wmma::load_matrix_sync(A_frag[i], &s_a[stage_sel][warp_smem_a_m][0], BK+OFFSET); 
      }

      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
        const int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
        wmma::load_matrix_sync(B_frag[j], &s_b[stage_sel][0][warp_smem_b_n], BN+OFFSET);
      }
      
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        #pragma unroll
        for (int j = 0; j < WARP_TILE_N; ++j) {
          wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
        }
      }
    }
  }

  // finally, store back to C matrix.
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      const int store_gmem_a_m = by * BM + warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      const int store_gmem_a_n = bx * BN + warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      wmma::store_matrix_sync(C + store_gmem_a_m * N + store_gmem_a_n, C_frag[i][j], N, 
                              wmma::mem_row_major);
    }
  }
}

// 1. 当使用的shared memory超过48 KB时，需要使用dynamic shared 
// memory， 即extern __shared__ half smem[];这样声明一块动态
// 共享内存，调用kernel时 需要指定动态共享内存大小，且smem的寻址
// 方式需要按照一维数组来使用 2. 提高L2 Cache的局部性(Thread 
// Block Swizzle): https://zhuanlan.zhihu.com/p/555339335
template<const int WMMA_M=16, const int WMMA_N=16, const int WMMA_K=16, 
         const int WMMA_TILE_M=4, const int WMMA_TILE_N=2, 
         const int WARP_TILE_M=2, const int WARP_TILE_N=4,
         const int K_STAGE=2, const int OFFSET=0,
         const int BLOCK_SWIZZLE = false>
__global__ void hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem_kernel(
  half* A, half* B, half* C, int M, int N, int K) {
  // 256 threads(8 warps) per block.
  // const int bx = blockIdx.x;
  // BLOCK_SWIZZLE 0/1 控制是否使用 block swizzle
  const int bx = ((int) BLOCK_SWIZZLE) * blockIdx.z * gridDim.x + blockIdx.x;
  const int by = blockIdx.y;
  const int NUM_K_TILES = div_ceil(K, WMMA_K);
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M; // 16x4*2=128
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N; // 16x2*4=128
  constexpr int BK = WMMA_K; // 16
  // s2: 2*128*(16+8)*2=12KB, 2*16*(128+8)*2=8.50KB,  ~21KB
  // s3: 3*128*(16+8)*2=18KB, 3*16*(128+8)*2=12.75KB, ~31KB
  // s4: 4*128*(16+8)*2=24KB, 4*16*(128+8)*2=17KB,    ~41KB
  // s5: 5*128*(16+8)*2=30KB, 5*16*(128+8)*2=21.25KB, ~52KB > 48KB
  extern __shared__ half smem[]; 
  half* s_a = smem;
  half* s_b = smem + K_STAGE * BM * (BK + OFFSET);
  constexpr int s_a_stage_offset = BM * (BK + OFFSET);
  constexpr int s_b_stage_offset = BK * (BN + OFFSET);

  // 要保证相同的warp下thread执行相同的指令
  const int tid = threadIdx.y * blockDim.x + threadIdx.x;
  const int warp_id = tid / WARP_SIZE; // 0~7 warp_id within block
  const int warp_m = warp_id / 2; // 0,1,2,3
  const int warp_n = warp_id % 2; // 0,1
  
  // 先计算shared memory中的索引
  // tid和需要加载的smem s_a[BM][BK] 之间的索引关系 BM=128 BK=16 按行读取 A行主序
  // 对于s_a每行16个数据，每个线程读取8个，需要2个线程；总共128行，需要128x2刚好256线程
  int load_smem_a_m = tid / 2; // row 0~127
  int load_smem_a_k = (tid % 2 == 0) ? 0 : 8; // col 0,8
  // tid和需要加载的smem s_b[BK][BN] 之间的索引关系 BK=16 BN=128 按行读取 B行主序
  // 对于s_b每行128个数据，每个线程读8个数据，需要16个线程；总共16行，需要16x16=256个线程
  int load_smem_b_k = tid / 16; // row 0~15
  int load_smem_b_n = (tid % 16) * 8; // col 0,8,...,120
  // 再计算全局内存中的索引
  // 要加载到s_a中的元素对应到A全局内存中的行数 每个block负责出C中大小为BM*BN的块
  int load_gmem_a_m = by * BM + load_smem_a_m; // global row of a and c
  int load_gmem_b_n = bx * BN + load_smem_b_n; // global col of b and c

  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> 
  C_frag[WARP_TILE_M][WARP_TILE_N];
  
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      wmma::fill_fragment(C_frag[i][j], 0.0);
    }
  }

  // only cvta smem base ptr once for cp.async.
  uint32_t smem_a_base_ptr = __cvta_generic_to_shared(s_a);
  uint32_t smem_b_base_ptr = __cvta_generic_to_shared(s_b);

  #pragma unroll
  for (int k = 0; k < (K_STAGE - 1); ++k) { // 0, 1
    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 
    
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (k * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr, &A[load_gmem_a_addr], 16);

    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (k * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);

    CP_ASYNC_COMMIT_GROUP();
  }

  CP_ASYNC_WAIT_GROUP(K_STAGE-2); // s2->0, s3->1, s4->2
  __syncthreads(); 

  #pragma unroll
  for (int k = (K_STAGE - 1); k < NUM_K_TILES; k++) { 
    // s2/4 can use bitwise ops but s3 can not, so, we use mod
    // ops for all stages kernel. s2: (k + 1)&1, s4: (k + 1)&3
    // s3: (k + 1) % 3
    int smem_sel = (k + 1) % K_STAGE; // s3 k 2->0, k 3->1, k 4->2...
    int smem_sel_next = k % K_STAGE;  // s3 k 2->2, k 3->0, k 4->1...

    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 

    // load stage 2, k start from 2
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (smem_sel_next * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr, &A[load_gmem_a_addr], 16);

    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (smem_sel_next * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);
    CP_ASYNC_COMMIT_GROUP();

    wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> A_frag[WARP_TILE_M];
    wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> B_frag[WARP_TILE_N];
    
    // compute stage 0
    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
      int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      half* load_smem_a_frag_ptr = (s_a + smem_sel * s_a_stage_offset + 
                                    warp_smem_a_m * (BK + OFFSET) 
                                    + 0); // BK=WMMA_K=16
      wmma::load_matrix_sync(A_frag[i], load_smem_a_frag_ptr, BK + OFFSET); 
    }

    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
      int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      half* load_smem_b_frag_ptr = (s_b + smem_sel * s_b_stage_offset + 
                                    0 * (BN + OFFSET) + 
                                    warp_smem_b_n); // BK=WMMA_K=16
      wmma::load_matrix_sync(B_frag[j], load_smem_b_frag_ptr, BN + OFFSET);
    }

    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
      }
    }

    CP_ASYNC_WAIT_GROUP(K_STAGE-2);
    __syncthreads(); 
  }
  
  // make sure all memory issues ready.
  if ((K_STAGE - 2) > 0) {
    CP_ASYNC_WAIT_GROUP(0);
    __syncthreads(); 
  }
  // processing last (K_STAGE-1) k iters.
  {
    #pragma unroll
    for (int k = 0; k < (K_STAGE - 1); k++) {
      const int stage_sel = ((NUM_K_TILES - (K_STAGE - 1) + k) % K_STAGE);
      wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> A_frag[WARP_TILE_M];
      wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> B_frag[WARP_TILE_N];
    
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
        int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
        half* load_smem_a_frag_ptr = (s_a + stage_sel * s_a_stage_offset + 
                                      warp_smem_a_m * (BK + OFFSET) 
                                      + 0); // BK=WMMA_K=16
        wmma::load_matrix_sync(A_frag[i], load_smem_a_frag_ptr, BK + OFFSET); 
      }

      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
        int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
        half* load_smem_b_frag_ptr = (s_b + stage_sel * s_b_stage_offset + 
                                      0 * (BN + OFFSET) + 
                                      warp_smem_b_n); // BK=WMMA_K=16
        wmma::load_matrix_sync(B_frag[j], load_smem_b_frag_ptr, BN + OFFSET);
      }
      
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        #pragma unroll
        for (int j = 0; j < WARP_TILE_N; ++j) {
          wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
        }
      }
    }
  }

  // finally, store back to C matrix.
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      const int store_gmem_a_m = by * BM + warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      const int store_gmem_a_n = bx * BN + warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      wmma::store_matrix_sync(C + store_gmem_a_m * N + store_gmem_a_n, C_frag[i][j], N, 
                              wmma::mem_row_major);
    }
  }
}

// stage with 256x128 block, dynamic smem
template<const int WMMA_M=16, const int WMMA_N=16, const int WMMA_K=16, 
         const int WMMA_TILE_M=4, const int WMMA_TILE_N=2, 
         const int WARP_TILE_M=4, const int WARP_TILE_N=4,
         const int K_STAGE=2, const int OFFSET=0,
         const int BLOCK_SWIZZLE = false>
__global__ void hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem_kernel(
  half* A, half* B, half* C, int M, int N, int K) {
  // 256 threads(8 warps) per block.
  // const int bx = blockIdx.x;
  // BLOCK_SWIZZLE 0/1 控制是否使用 block swizzle
  const int bx = ((int) BLOCK_SWIZZLE) * blockIdx.z * gridDim.x + blockIdx.x;
  const int by = blockIdx.y;
  const int NUM_K_TILES = div_ceil(K, WMMA_K);
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M; // 16x4*4=256
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N; // 16x2*4=128
  constexpr int BK = WMMA_K; // 16
  // s2: 2*256*(16+8)*2=24KB, 2*16*(128+8)*2=8.50KB,  ~31KB
  // s3: 3*256*(16+8)*2=36KB, 3*16*(128+8)*2=12.75KB, ~39KB
  // s4: 4*256*(16+8)*2=48KB, 4*16*(128+8)*2=17KB,    ~65KB > 48KB
  // s5: 5*256*(16+8)*2=60KB, 5*16*(128+8)*2=21.25KB, ~82KB > 48KB
  extern __shared__ half smem[]; 
  half* s_a = smem;
  half* s_b = smem + K_STAGE * BM * (BK + OFFSET);
  constexpr int s_a_stage_offset = BM * (BK + OFFSET);
  constexpr int s_b_stage_offset = BK * (BN + OFFSET);

  // 要保证相同的warp下thread执行相同的指令
  const int tid = threadIdx.y * blockDim.x + threadIdx.x;
  const int warp_id = tid / WARP_SIZE; // 0~7 warp_id within block
  const int warp_m = warp_id / 2; // 0,1,2,3
  const int warp_n = warp_id % 2; // 0,1
  
  // 先计算shared memory中的索引
  // tid和需要加载的smem s_a[BM][BK] 之间的索引关系 BM=256 BK=16 按行读取 A行主序
  // 对于s_a每行16个数据，每个线程读取16个，需要1个线程；总共256行，需要刚好256线程
  int load_smem_a_m = tid; // row 0~255
  int load_smem_a_k = 0; // col 0
  // tid和需要加载的smem s_b[BK][BN] 之间的索引关系 BK=16 BN=128 按行读取 B行主序
  // 对于s_b每行128个数据，每个线程读8个数据，需要16个线程；总共16行，需要16x16=256个线程
  int load_smem_b_k = tid / 16; // row 0~15
  int load_smem_b_n = (tid % 16) * 8; // col 0,8,...,120
  // 再计算全局内存中的索引
  // 要加载到s_a中的元素对应到A全局内存中的行数 每个block负责出C中大小为BM*BN的块
  int load_gmem_a_m = by * BM + load_smem_a_m; // global row of a and c
  int load_gmem_b_n = bx * BN + load_smem_b_n; // global col of b and c

  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, half> 
  C_frag[WARP_TILE_M][WARP_TILE_N];
  
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      wmma::fill_fragment(C_frag[i][j], 0.0);
    }
  }

  // only cvta smem base ptr once for cp.async.
  uint32_t smem_a_base_ptr = __cvta_generic_to_shared(s_a);
  uint32_t smem_b_base_ptr = __cvta_generic_to_shared(s_b);

  #pragma unroll
  for (int k = 0; k < (K_STAGE - 1); ++k) { // 0, 1
    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 
    
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (k * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr,      &A[load_gmem_a_addr    ], 16);
    CP_ASYNC_CG(load_smem_a_ptr + 16, &A[load_gmem_a_addr + 8], 16);

    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (k * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);

    CP_ASYNC_COMMIT_GROUP();
  }

  CP_ASYNC_WAIT_GROUP(K_STAGE-2); // s2->0, s3->1, s4->2
  __syncthreads(); 

  #pragma unroll
  for (int k = (K_STAGE - 1); k < NUM_K_TILES; k++) { 
    // s2/4 can use bitwise ops but s3 can not, so, we use mod
    // ops for all stages kernel. s2: (k + 1)&1, s4: (k + 1)&3
    // s3: (k + 1) % 3
    int smem_sel = (k + 1) % K_STAGE; // s3 k 2->0, k 3->1, k 4->2...
    int smem_sel_next = k % K_STAGE;  // s3 k 2->2, k 3->0, k 4->1...

    // k * WMMA_K, WMMA_K=16 -> (k << 4)
    int load_gmem_a_k = k * WMMA_K + load_smem_a_k; // global col of a
    int load_gmem_a_addr = load_gmem_a_m * K + load_gmem_a_k;
    int load_gmem_b_k = k * WMMA_K + load_smem_b_k; // global row of b
    int load_gmem_b_addr = load_gmem_b_k * N + load_gmem_b_n; 

    // load stage 2, k start from 2
    uint32_t load_smem_a_ptr = (
      smem_a_base_ptr + (smem_sel_next * s_a_stage_offset + 
                         load_smem_a_m * (BK + OFFSET) + 
                         load_smem_a_k) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_a_ptr,      &A[load_gmem_a_addr    ], 16);
    CP_ASYNC_CG(load_smem_a_ptr + 16, &A[load_gmem_a_addr + 8], 16);

    uint32_t load_smem_b_ptr = (
      smem_b_base_ptr + (smem_sel_next * s_b_stage_offset + 
                         load_smem_b_k * (BN + OFFSET) + 
                         load_smem_b_n) * sizeof(half)
    );
    CP_ASYNC_CG(load_smem_b_ptr, &B[load_gmem_b_addr], 16);
    CP_ASYNC_COMMIT_GROUP();

    wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> A_frag[WARP_TILE_M];
    wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                   wmma::row_major> B_frag[WARP_TILE_N];
    
    // compute stage 0
    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
      int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      half* load_smem_a_frag_ptr = (s_a + smem_sel * s_a_stage_offset + 
                                    warp_smem_a_m * (BK + OFFSET) 
                                    + 0); // BK=WMMA_K=16
      wmma::load_matrix_sync(A_frag[i], load_smem_a_frag_ptr, BK + OFFSET); 
    }

    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
      int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      half* load_smem_b_frag_ptr = (s_b + smem_sel * s_b_stage_offset + 
                                    0 * (BN + OFFSET) + 
                                    warp_smem_b_n); // BK=WMMA_K=16
      wmma::load_matrix_sync(B_frag[j], load_smem_b_frag_ptr, BN + OFFSET);
    }

    #pragma unroll
    for (int i = 0; i < WARP_TILE_M; ++i) {
      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
      }
    }

    CP_ASYNC_WAIT_GROUP(K_STAGE-2);
    __syncthreads(); 
  }
  
  // make sure all memory issues ready.
  if ((K_STAGE - 2) > 0) {
    CP_ASYNC_WAIT_GROUP(0);
    __syncthreads(); 
  }
  // processing last (K_STAGE-1) k iters.
  {
    #pragma unroll
    for (int k = 0; k < (K_STAGE - 1); k++) {
      const int stage_sel = ((NUM_K_TILES - (K_STAGE - 1) + k) % K_STAGE);
      wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> A_frag[WARP_TILE_M];
      wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, 
                     wmma::row_major> B_frag[WARP_TILE_N];
    
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        // load 2 tiles -> reg, smem a -> frags a, warp_m 0~3
        int warp_smem_a_m = warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
        half* load_smem_a_frag_ptr = (s_a + stage_sel * s_a_stage_offset + 
                                      warp_smem_a_m * (BK + OFFSET) 
                                      + 0); // BK=WMMA_K=16
        wmma::load_matrix_sync(A_frag[i], load_smem_a_frag_ptr, BK + OFFSET); 
      }

      #pragma unroll
      for (int j = 0; j < WARP_TILE_N; ++j) {
        // load 4 tiles -> reg, smem b -> frags b, warp_n 0~2
        int warp_smem_b_n = warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
        half* load_smem_b_frag_ptr = (s_b + stage_sel * s_b_stage_offset + 
                                      0 * (BN + OFFSET) + 
                                      warp_smem_b_n); // BK=WMMA_K=16
        wmma::load_matrix_sync(B_frag[j], load_smem_b_frag_ptr, BN + OFFSET);
      }
      
      #pragma unroll
      for (int i = 0; i < WARP_TILE_M; ++i) {
        #pragma unroll
        for (int j = 0; j < WARP_TILE_N; ++j) {
          wmma::mma_sync(C_frag[i][j], A_frag[i], B_frag[j], C_frag[i][j]);
        }
      }
    }
  }

  // finally, store back to C matrix.
  #pragma unroll
  for (int i = 0; i < WARP_TILE_M; ++i) {
    #pragma unroll
    for (int j = 0; j < WARP_TILE_N; ++j) {
      const int store_gmem_a_m = by * BM + warp_m * (WMMA_M * WARP_TILE_M) + i * WMMA_M;
      const int store_gmem_a_n = bx * BN + warp_n * (WMMA_N * WARP_TILE_N) + j * WMMA_N;
      wmma::store_matrix_sync(C + store_gmem_a_m * N + store_gmem_a_n, C_frag[i][j], N, 
                              wmma::mem_row_major);
    }
  }
}

// TODO: Warp swizzle support ? (MMA, not WMMA)

// --------------------- PyTorch bindings for custom kernel -----------------------
#define STRINGFY(str) #str
#define TORCH_BINDING_COMMON_EXTENSION(func)   \
  m.def(STRINGFY(func), &func, STRINGFY(func));

#define CHECK_TORCH_TENSOR_DTYPE(T, th_type)                 \
if(((T).options().dtype() != (th_type))) {                   \
  std::cout << "Tensor Info:" << (T).options() << std::endl; \
  throw std::runtime_error("values must be "#th_type);       \
}

#define CHECK_TORCH_TENSOR_SHAPE(T, S0, S1)           \
if (((T).size(0) != (S0)) || ((T).size(1) != (S1))) { \
  throw std::runtime_error("Tensor size mismatch!");  \
}

// 128x128 w/o dynamic smem
#define LAUNCH_161616_STAGE_SWIZZLE_KERNEL(stages, stride)   \
{                                                            \
  const int N_SWIZZLE = (N + (stride) - 1) / (stride);       \
  dim3 block(NUM_THREADS);                                   \
  dim3 grid((div_ceil(N, BN) + N_SWIZZLE - 1) / N_SWIZZLE,   \
             div_ceil(M, BM),                                \
             N_SWIZZLE);                                     \
  hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_kernel<         \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,        \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, true><<<     \
    grid, block>>>(                                          \
    reinterpret_cast<half*>(a.data_ptr()),                   \
    reinterpret_cast<half*>(b.data_ptr()),                   \
    reinterpret_cast<half*>(c.data_ptr()),                   \
    M, N, K                                                  \
  );                                                         \
}

#define LAUNCH_161616_STAGE_NO_SWIZZLE_KERNEL(stages)        \
{                                                            \
  dim3 block(NUM_THREADS);                                   \
  dim3 grid(div_ceil(N, BN), div_ceil(M, BM));               \
  hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_kernel<         \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,        \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, false><<<    \
    grid, block>>>(                                          \
    reinterpret_cast<half*>(a.data_ptr()),                   \
    reinterpret_cast<half*>(b.data_ptr()),                   \
    reinterpret_cast<half*>(c.data_ptr()),                   \
    M, N, K                                                  \
  );                                                         \
}

// 128x128 w dynamic smem, 98304=96KB < Ampere, Ada, Hopper ...
#define LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(stages, stride)  \
{                                                                 \
  const int smem_max_size = (                                     \
    (stages) * BM * (BK + OFFSET) * sizeof(half) +                \
    (stages) * BK * (BN + OFFSET) * sizeof(half));                \
  cudaFuncSetAttribute(                                           \
    hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem_kernel<      \
      WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,           \
      WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, true>,          \
    cudaFuncAttributeMaxDynamicSharedMemorySize,                  \
    98304);                                                       \
  const int N_SWIZZLE = (N + (stride) - 1) / (stride);            \
  dim3 block(NUM_THREADS);                                        \
  dim3 grid((div_ceil(N, BN) + N_SWIZZLE - 1) / N_SWIZZLE,        \
             div_ceil(M, BM),                                     \
             N_SWIZZLE);                                          \
  hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem_kernel<        \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,             \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, true><<<          \
    grid, block, smem_max_size>>>(                                \
    reinterpret_cast<half*>(a.data_ptr()),                        \
    reinterpret_cast<half*>(b.data_ptr()),                        \
    reinterpret_cast<half*>(c.data_ptr()),                        \
    M, N, K                                                       \
  );                                                              \
}

#define LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(stages)    \
{                                                              \
  const int smem_max_size = (                                  \
    (stages) * BM * (BK + OFFSET) * sizeof(half) +             \
    (stages) * BK * (BN + OFFSET) * sizeof(half));             \
  cudaFuncSetAttribute(                                        \
    hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem_kernel<   \
      WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,        \
      WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, false>,      \
    cudaFuncAttributeMaxDynamicSharedMemorySize,               \
    98304);                                                    \
  dim3 block(NUM_THREADS);                                     \
  dim3 grid(div_ceil(N, BN), div_ceil(M, BM));                 \
  hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem_kernel<     \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,          \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, false><<<      \
    grid, block, smem_max_size>>>(                             \
    reinterpret_cast<half*>(a.data_ptr()),                     \
    reinterpret_cast<half*>(b.data_ptr()),                     \
    reinterpret_cast<half*>(c.data_ptr()),                     \
    M, N, K                                                    \
  );                                                           \
}

// 256x128 w dynamic smem, 98304=96KB < Ampere, Ada, Hopper ...
#define LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(stages, stride)  \
{                                                                         \
  const int smem_max_size = (                                             \
    (stages) * BM * (BK + OFFSET) * sizeof(half) +                        \
    (stages) * BK * (BN + OFFSET) * sizeof(half));                        \
  cudaFuncSetAttribute(                                                   \
    hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem_kernel<              \
      WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,                   \
      WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, true>,                  \
    cudaFuncAttributeMaxDynamicSharedMemorySize,                          \
    98304);                                                               \
  const int N_SWIZZLE = (N + (stride) - 1) / (stride);                    \
  dim3 block(NUM_THREADS);                                                \
  dim3 grid((div_ceil(N, BN) + N_SWIZZLE - 1) / N_SWIZZLE,                \
             div_ceil(M, BM),                                             \
             N_SWIZZLE);                                                  \
  hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem_kernel<                \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,                     \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, true><<<                  \
    grid, block, smem_max_size>>>(                                        \
    reinterpret_cast<half*>(a.data_ptr()),                                \
    reinterpret_cast<half*>(b.data_ptr()),                                \
    reinterpret_cast<half*>(c.data_ptr()),                                \
    M, N, K                                                               \
  );                                                                      \
}

#define LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(stages)       \
{                                                                         \
  const int smem_max_size = (                                             \
    (stages) * BM * (BK + OFFSET) * sizeof(half) +                        \
    (stages) * BK * (BN + OFFSET) * sizeof(half));                        \
  cudaFuncSetAttribute(                                                   \
    hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem_kernel<              \
      WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,                   \
      WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, false>,                 \
    cudaFuncAttributeMaxDynamicSharedMemorySize,                          \
    98304);                                                               \
  dim3 block(NUM_THREADS);                                                \
  dim3 grid(div_ceil(N, BN), div_ceil(M, BM));                            \
  hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem_kernel<                \
    WMMA_M, WMMA_N, WMMA_K, WMMA_TILE_M, WMMA_TILE_N,                     \
    WARP_TILE_M, WARP_TILE_N, (stages), OFFSET, false><<<                 \
    grid, block, smem_max_size>>>(                                        \
    reinterpret_cast<half*>(a.data_ptr()),                                \
    reinterpret_cast<half*>(b.data_ptr()),                                \
    reinterpret_cast<half*>(c.data_ptr()),                                \
    M, N, K                                                               \
  );                                                                      \
}

// stage 2/3/4 w/o block swizzle across N dim, static smem < 48KB
void hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages(
  torch::Tensor a, torch::Tensor b, torch::Tensor c, 
  int stages, bool swizzle, int swizzle_stride) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(b, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(c, torch::kHalf)
  const int M = a.size(0);
  const int K = a.size(1);
  const int N = b.size(1); 
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(b, K, N)
  CHECK_TORCH_TENSOR_SHAPE(c, M, N)
  constexpr int WMMA_M = 16;
  constexpr int WMMA_N = 16;
  constexpr int WMMA_K = 16;
  constexpr int WMMA_TILE_M = 4;
  constexpr int WMMA_TILE_N = 2; 
  constexpr int WARP_TILE_M = 2;
  constexpr int WARP_TILE_N = 4;
  constexpr int OFFSET = 8;
  constexpr int NUM_THREADS= (
    WMMA_TILE_M * WMMA_TILE_N * WARP_SIZE); // 2 * 4 * 32 = 256
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M;    
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N;    
  constexpr int BK = WMMA_K;                                
  
  if (swizzle) {
    assert(swizzle_stride % 256 == 0);
    switch (stages)
    {
    case 2: // ~21KB
      LAUNCH_161616_STAGE_SWIZZLE_KERNEL(2, swizzle_stride);
      break;
    case 3: // ~31KB
      LAUNCH_161616_STAGE_SWIZZLE_KERNEL(3, swizzle_stride);
      break;
    case 4: // ~41K
      LAUNCH_161616_STAGE_SWIZZLE_KERNEL(4, swizzle_stride);
      break;
    default:
      LAUNCH_161616_STAGE_SWIZZLE_KERNEL(2, swizzle_stride);
      break;
    }
  } else {
    switch (stages)
    {
    case 2:
      LAUNCH_161616_STAGE_NO_SWIZZLE_KERNEL(2);
      break;
    case 3:
      LAUNCH_161616_STAGE_NO_SWIZZLE_KERNEL(3);
      break;
    case 4:
      LAUNCH_161616_STAGE_NO_SWIZZLE_KERNEL(4);
      break;
    default:
      LAUNCH_161616_STAGE_NO_SWIZZLE_KERNEL(2);
      break;
    }
  }
}

// stage 2/3/4 + dynamic smem, w/o block swizzle across N dim
void hgemm_wmma_m16n16k16_mma4x2_warp2x4_stages_dsmem(
  torch::Tensor a, torch::Tensor b, torch::Tensor c, 
  int stages, bool swizzle, int swizzle_stride) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(b, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(c, torch::kHalf)
  const int M = a.size(0);
  const int K = a.size(1);
  const int N = b.size(1); 
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(b, K, N)
  CHECK_TORCH_TENSOR_SHAPE(c, M, N)
  constexpr int WMMA_M = 16;
  constexpr int WMMA_N = 16;
  constexpr int WMMA_K = 16;
  constexpr int WMMA_TILE_M = 4;
  constexpr int WMMA_TILE_N = 2; 
  constexpr int WARP_TILE_M = 2;
  constexpr int WARP_TILE_N = 4;
  constexpr int OFFSET = 8;
  constexpr int NUM_THREADS= (
    WMMA_TILE_M * WMMA_TILE_N * WARP_SIZE); // 2 * 4 * 32 = 256
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M;    
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N;    
  constexpr int BK = WMMA_K;         
  
  if (swizzle) {
    assert(swizzle_stride % 256 == 0);
    switch (stages)
    {
    case 2: // ~21KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(2, swizzle_stride);
      break;
    case 3: // ~31KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(3, swizzle_stride);
      break;
    case 4: // ~41K
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(4, swizzle_stride);
      break;
    case 5: // ~52KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(5, swizzle_stride);
      break;
    default:
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_KERNEL(2, swizzle_stride);
      break;
    }
  } else {
    switch (stages)
    {
    case 2:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(2);
      break;
    case 3:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(3);
      break;
    case 4:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(4);
      break;
    case 5:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(5);
      break;
    default:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_KERNEL(2);
      break;
    }
  }
}

// 256x128 stage 2/3/4 + dynamic smem, w/o block swizzle across N dim
void hgemm_wmma_m16n16k16_mma4x2_warp4x4_stages_dsmem(
  torch::Tensor a, torch::Tensor b, torch::Tensor c, 
  int stages, bool swizzle, int swizzle_stride) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(b, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(c, torch::kHalf)
  const int M = a.size(0);
  const int K = a.size(1);
  const int N = b.size(1); 
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(b, K, N)
  CHECK_TORCH_TENSOR_SHAPE(c, M, N)
  constexpr int WMMA_M = 16;
  constexpr int WMMA_N = 16;
  constexpr int WMMA_K = 16;
  constexpr int WMMA_TILE_M = 4;
  constexpr int WMMA_TILE_N = 2; 
  constexpr int WARP_TILE_M = 4;
  constexpr int WARP_TILE_N = 4;
  constexpr int OFFSET = 8;
  constexpr int NUM_THREADS= (
    WMMA_TILE_M * WMMA_TILE_N * WARP_SIZE); // 2 * 4 * 32 = 256
  constexpr int BM = WMMA_M * WMMA_TILE_M * WARP_TILE_M;    
  constexpr int BN = WMMA_N * WMMA_TILE_N * WARP_TILE_N;    
  constexpr int BK = WMMA_K;         
  
  if (swizzle) {
    assert(swizzle_stride % 256 == 0);
    switch (stages)
    {
    case 2: // ~31KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(2, swizzle_stride);
      break;
    case 3: // ~39KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(3, swizzle_stride);
      break;
    case 4: // ~65K
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(4, swizzle_stride);
      break;
    case 5: // ~82KB
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(5, swizzle_stride);
      break;
    default:
      LAUNCH_161616_STAGE_SWIZZLE_DSMEM_256x128_KERNEL(2, swizzle_stride);
      break;
    }
  } else {
    switch (stages)
    {
    case 2:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(2);
      break;
    case 3:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(3);
      break;
    case 4:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(4);
      break;
    case 5:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(5);
      break;
    default:
      LAUNCH_161616_STAGE_NO_SWIZZLE_DSMEM_256x128_KERNEL(2);
      break;
    }
  }
}
