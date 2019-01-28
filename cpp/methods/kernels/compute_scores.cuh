#pragma once

#include <catboost/cuda/cuda_lib/kernel/kernel.cuh>
#include <catboost/cuda/cuda_util/gpu_data/partitions.h>
#include <catboost/cuda/gpu_data/gpu_structures.h>
#include <catboost/libs/options/enums.h>

namespace NKernel {


    void ComputeOptimalSplits(const TCBinFeature* binaryFeatures,
                              ui32 binaryFeatureCount,
                              const float* histograms,
                              const double* partStats, int statCount,
                              const ui32* partIds, int partBlockSize, int partBlockCount,
                              TBestSplitProperties* result,
                              ui32 argmaxBlockCount,
                              EScoreFunction scoreFunction,
                              bool multiclassOptimization,
                              double l2,
                              ui64 seed,
                              TCudaStream stream);



};
