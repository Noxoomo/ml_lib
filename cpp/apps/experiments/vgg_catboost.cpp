#include "common.h"
#include "common_em.h"
#include "catboost_nn.h"

#include <experiments/core/networks/vgg.h>
#include <experiments/datasets/cifar10/cifar10_reader.h>
#include <experiments/core/optimizer.h>
#include <experiments/core/cross_entropy_loss.h>
#include <experiments/core/em_like_train.h>
#include <experiments/core/transform.h>

#include <torch/torch.h>
#include <string>
#include <memory>
#include <iostream>
#include <experiments/core/polynom_model.h>
#include <models/polynom/polynom.h>

using namespace  experiments;
int main(int argc, char* argv[]) {
    auto device = torch::kCPU;
    if (argc > 1 && std::string(argv[1]) == std::string("CUDA")
        && torch::cuda::is_available()) {
        device = torch::kCUDA;
        std::cout << "Using CUDA device for training" << std::endl;
    } else {
        std::cout << "Using CPU device for training" << std::endl;
    }

    // Read dataset

    const std::string& path = "../../../../resources/cifar10/cifar-10-batches-bin";
    auto dataset = experiments::cifar10::read_dataset(path);

    // Init model


    CatBoostNNConfig catBoostNnConfig;
    catBoostNnConfig.batchSize = 128;
    catBoostNnConfig.dropOut_ = 0.0;
    catBoostNnConfig.lambda_ = 1.0;
    catBoostNnConfig.sgdStep_ = 0.1;
    catBoostNnConfig.representationsIterations = 20;

    catBoostNnConfig.catboostParamsFile = "../../../../cpp/apps/cifar_networks/vgg_params/catboost_params_gpu.json";
    catBoostNnConfig.catboostInitParamsFile = "../../../../cpp/apps/cifar_networks/vgg_params/catboost_params_init.json";
    catBoostNnConfig.catboostFinalParamsFile = "../../../../cpp/apps/cifar_networks/vgg_params/catboost_params_final.json";
    torch::setNumThreads(16);
    PolynomPtr polynom = std::make_shared<Polynom>();
    polynom->Lambda_ = catBoostNnConfig.lambda_;
    {
        Monom emptyMonom;
        emptyMonom.Structure_ .Splits.push_back({0, 0});
        const auto outDim = 10;
        emptyMonom.Values_.resize(outDim);
        polynom->Ensemble_.push_back(emptyMonom);
    }

//    auto classifier = makeClassifierWithBaseline<PolynomModel>(
//        makeCifarLinearClassifier(512),
//        polynom);


    auto classifier = makeClassifierWithBaseline<PolynomModel>(
        makeCifarBias(),
        polynom);

//    auto classifier = makeClassifier<PolynomModel>(polynom);

    auto vgg = std::make_shared<Vgg>(VggConfiguration::Vgg16, classifier);
    vgg->to(device);

    CatBoostNN nnTrainer(catBoostNnConfig,
        vgg,
        device,
        makeClassifier<experiments::LinearCifarClassifier>(512));
    // Attach Listeners

    auto mds = dataset.second.map(getDefaultCifar10TestTransform());

    nnTrainer.registerGlobalIterationListener([&](uint32_t epoch, experiments::ModelPtr model) {
        AccuracyCalcer<decltype(mds)>(device, catBoostNnConfig, mds, nnTrainer)(epoch, model);
    });


    nnTrainer.registerGlobalIterationListener([&](uint32_t epoch, experiments::ModelPtr model) {
        if (epoch % 2 == 0) {
            return;
        }
        std::cout << "--------===============CATBOOST learn + test start ====================---------------  "  << std::endl;
        auto learn = nnTrainer.applyConvLayers(dataset.first.map(getCifar10TrainFinalCatboostTransform()));
        auto test =  nnTrainer.applyConvLayers(dataset.second.map(getDefaultCifar10TestTransform()));
        nnTrainer.trainFinalDecision(learn, test);
        std::cout << "--------===============CATBOOST learn + test finish ====================---------------  "  << std::endl;
    });

    // Train

    auto loss = std::make_shared<CrossEntropyLoss>();
    nnTrainer.train(dataset.first, loss);

    // Eval model

    auto acc = evalModelTestAccEval(dataset.second,
                                    vgg,
                                    device,
                                    getDefaultCifar10TestTransform());

    std::cout << "VGG EM test accuracy: " << std::setprecision(2)
              << acc << "%" << std::endl;
}
