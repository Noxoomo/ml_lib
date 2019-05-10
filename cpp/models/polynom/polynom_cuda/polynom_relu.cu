#include <cuda_runtime.h>
#include <iostream>
#include <cassert>
#if __CUDA_ARCH__ < 350
template <typename T>
__forceinline__ __device__ T __ldg(const T* data) {
    return data[0];
}
#endif

__forceinline__ __device__ float Sigmoid(float x) {
    return 1.0f / (1.0f + expf(-x));
}

__forceinline__ __device__ float Relu(float x) {
    return max(x, 0.0f);
}

__forceinline__ __device__ float ReluDer(float x) {
    return x > 0;
}

__forceinline__ __device__ float SigmoidDer(float x) {
    const float p = 1.0f / (1.0f + expf(-x));
    return p * (1.0f - p);
}

__global__ void PolynomProbsImpl(
    const float* features,
    int batchSize,
    const int* splits,
    const float* conditions,
    const int* polynomOffsets,
    int polynomCount,
    float lambda,
    float* probs) {
    if (threadIdx.x < batchSize) {
        int polynomId = blockIdx.x;

        features +=  threadIdx.x;
        probs += threadIdx.x;

        while (polynomId < polynomCount) {
            int offset = polynomOffsets[polynomId];
            int nextOffset = polynomOffsets[polynomId + 1];
            const int depth = nextOffset - offset;

            float prob = 1.0;
            for (int i = 0; i < depth; ++i) {
                const int f = __ldg(splits + offset + i);
                const float c = __ldg(conditions + offset + i);
                const float x = __ldg(features + f * batchSize);
                const float val = Relu(lambda * x - c);
//                const float expVal = 1.0f + exp(expal);

//            p( split = 1) = 1.0 / (1.0 + exp(-(x - c)))
//            c = 0, x= inf, p = 1.0 / (1.0 + exp(-inf) = 0
//            log(p) = -log(1.0 + exp(-(x - c))
//                const float isTrueLogProb = isfinite(expVal) ? log(expVal) : val;
//                logProb -= isTrueLogProb;
                prob *= val;
            }
//            const float prob = exp(logProb);
            probs[polynomId * batchSize] = prob;
            polynomId += gridDim.x;
        }
    }
}

//batch size should be equal to BlockSize
//we need to reduce polynoms for each output dim
__global__ void PolynomForwardImpl(
    const float* probs,
    int batchSize,
    const float* values,
    int polynomCount,
    int outputDim,
    float* out) {

    //out: batch_elem0 dim0, dim1, dimk batch_elem1 dim0 dim1 dimk
    //so threads
    int polynomId = blockIdx.x;
    const int dimId = blockIdx.y;

    int tid = threadIdx.x;
    if (tid >= batchSize) {
        return;
    }

    float sum = 0;
    probs += threadIdx.x;
    values += dimId;

    while (polynomId < polynomCount) {
        const float polynomProb = __ldg(probs + polynomId * batchSize);
        const float out = __ldg(values + polynomId * outputDim);
        sum += polynomProb * out;
        polynomId += gridDim.x;
    }

    atomicAdd(out + dimId * batchSize + threadIdx.x, sum);
}


//

//
void PolynomForward(
    const float lambda,
    const float* features,
    int fCount,
    int batchSize,
    const int* splits,
    const float* conditions,
    const int* polynomOffsets,
    const float* values,
    int polynomCount,
    int outDim,
    float* tempProbs,
    float* output
) {
    const int blockSize = batchSize;
    const int numBlocks = min(polynomCount, 1000);
    assert(batchSize < 2048);
    assert(numBlocks);

    PolynomProbsImpl << < numBlocks, blockSize >>> (features, batchSize, splits, conditions, polynomOffsets, polynomCount, lambda, tempProbs);

    dim3 forwardBlocks;
    forwardBlocks.z = 1;
    forwardBlocks.y = outDim;
    forwardBlocks.x = min(polynomCount, 512);
    PolynomForwardImpl << < forwardBlocks, batchSize >> > (tempProbs, batchSize, values, polynomCount, outDim, output);
}

//
//
/*
 * Here layout is not the same as in forward pass
 * BlockSize = 256, MaxDepth = 8, K = 24
 * should give 50% occupancy, this should be enough
 */
template <int MaxDepth, int BlockSize, int K>
__global__ void PolynomBackwardImpl(float lambda,
                                    const float* features,
                                    int featuresCount,
                                    const float* outDer,
                                    int outputDim,
                                    const int* featureIds,
                                    const float* conditions,
                                    const float* values,
                                    const int* polynomOffsets,
                                    int polynomCount,
                                    float* featuresDer) {
    const int sampleId = blockIdx.y;

    features += sampleId * featuresCount;
    featuresDer += sampleId * featuresCount;
    outDer += sampleId * outputDim;


    //out: batch_elem0 dim0, dim1, dimk batch_elem1 dim0 dim1 dimk
    //so threads

    __shared__ float localFeaturesDer[BlockSize * K];

    for (int i = threadIdx.x; i < BlockSize * K; i += BlockSize) {
        localFeaturesDer[i] = 0;
    }
    __syncthreads();


    const int alignedFeaturesCount = ((featuresCount + BlockSize - 1) / BlockSize) * BlockSize;

    const int memoryBlocks = (BlockSize * K) / alignedFeaturesCount;
    const int memoryBlockId = threadIdx.x % memoryBlocks;


    int polynomId = blockIdx.x * blockDim.x + threadIdx.x;

    while (polynomId < polynomCount) {
        const int offset = polynomOffsets[polynomId];
        const int nextOffset = polynomOffsets[polynomId + 1];
        const int depth = nextOffset - offset;

        if (depth != 0) {

            float probs[MaxDepth];
            float ders[MaxDepth];
            short fids[MaxDepth];
//            float totalLogProb = 0;

            #pragma unroll
            for (int i = 0; i < MaxDepth; ++i) {
                if (i < depth) {
                    const int f = __ldg(featureIds + i + offset);
                    fids[i] = f;
                    const float c = __ldg(conditions + i + offset);
                    const float x = __ldg(features + f);
//                    const float val = l
//                    const float expVal = 1.0f + exp(val);
                    probs[i] =  Relu(lambda * x - c);//-(isfinite(expVal) ? log(expVal) : val);
                    ders[i] =  ReluDer(lambda * x - c);//-(isfinite(expVal) ? log(expVal) : val);
//                    totalLogProb += logProbs[i];
                }
            }

//            const float p = max(exp(totalLogProb), 1e-2f);

            //featureDerivative is outputDer * total value before monom * monom derivative
            float derMultiplier = 0;
            #pragma unroll 10
            for (int dim = 0; dim < outputDim; ++dim) {
                derMultiplier += __ldg(values + polynomId * outputDim + dim) * __ldg(outDer + dim);
            }

            #pragma unroll
            for (int i = 0; i < MaxDepth; ++i) {
                if (i < depth) {
                    const int f = fids[i];
                    float monomDer = 1.0;
                    for (int j = 0; j < MaxDepth; ++j) {
                        if (j < depth) {
                            if (i == j) {
                                monomDer *= ders[j];
                            } else {
                                monomDer *= probs[j];
                            }
                        }
                    }
//                    const float featureProb = min(exp(logProbs[i]), 0.99f);
//                    const float monomDer = p * (1.0 - featureProb);
                    const float featureDer = monomDer * derMultiplier;
                    //atomics in shared memory, pretty fast on pascal+ hardware
                    atomicAdd(localFeaturesDer + memoryBlocks * f + memoryBlockId, featureDer);
                }
            }
        }
        polynomId += gridDim.x * blockDim.x;
    }


    __syncthreads();

    //outputDim = 1024 => memoryBlocks = 6
    for (int f = threadIdx.x; f < featuresCount; f += BlockSize) {
        float der = 0;

        #pragma unroll
        for (int k = 0; k < memoryBlocks; ++k) {
            der += localFeaturesDer[f * memoryBlocks + k];
        }
        atomicAdd(featuresDer + f,  der);
    }
}


void PolynomBackward(int batchSize,
                     float lambda,
                     const float* features,
                     int featuresCount,
                     const float* outDer,
                     int outputDim,
                     const int* featureIds,
                     const float* conditions,
                     const float* values,
                     const int* polynomOffsets,
                     int polynomCount,
                     float* featuresDer) {

    const int blockSize = 256;
    dim3 numBlocks;
    numBlocks.z = 1;
    numBlocks.y = batchSize;
    //should be ≈ smCount * 6 / batchSize
    numBlocks.x = min((polynomCount + blockSize - 1) * outputDim / blockSize, 160);

    const int maxDepth = 8;
    const int K = 16;

    PolynomBackwardImpl<maxDepth, blockSize, K> <<<numBlocks, blockSize>>>(lambda, features, featuresCount, outDer, outputDim, featureIds, conditions, values, polynomOffsets, polynomCount, featuresDer);

}
//

