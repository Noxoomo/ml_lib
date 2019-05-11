#include "common.h"
#include "common_em.h"

#include <experiments/core/networks/lenet.h>
#include <experiments//datasets/cifar10/cifar10_reader.h>
#include <experiments/core/optimizer.h>
#include <experiments/core/cross_entropy_loss.h>
#include <experiments/core/em_like_train.h>

#include <torch/torch.h>

#include <string>
#include <memory>
#include <iostream>

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

    auto lenetConv = std::make_shared<LeNetConv>();
    lenetConv->to(device);

    auto linearClassifier = std::make_shared<LinearClassifier>(16 * 5 * 5, 10);
//    auto linearClassifier = std::make_shared<LeNetClassifier>();
    linearClassifier->to(device);

    ExactLinearEm emTrainer({5, 2, 4}, lenetConv, linearClassifier, device);
//    CommonEm emTrainer({5, 2, 4}, lenetConv, linearClassifier, device);

    // Attach Listeners

    auto mds = dataset.second.map(getDefaultCifar10TestTransform());
    emTrainer.registerGlobalIterationListener([&](uint32_t epoch, experiments::ModelPtr model) {
        model->eval();

        auto dloader = torch::data::make_data_loader(mds, torch::data::DataLoaderOptions(128));
        int rightAnswersCnt = 0;

        for (auto& batch : *dloader) {
            auto data = batch.data;
            data = data.to(device);
            torch::Tensor target = batch.target;

            torch::Tensor prediction = model->forward(data);
            prediction = torch::argmax(prediction, 1);

            prediction = prediction.to(torch::kCPU);

            auto targetAccessor = target.accessor<int64_t, 1>();
            auto predictionsAccessor = prediction.accessor<int64_t, 1>();
            int size = target.size(0);

            for (int i = 0; i < size; ++i) {
                const int targetClass = targetAccessor[i];
                const int predictionClass = predictionsAccessor[i];
                if (targetClass == predictionClass) {
                    rightAnswersCnt++;
                }
            }
        }

        std::cout << "Test accuracy: " <<  rightAnswersCnt * 100.0f / dataset.second.size().value() << std::endl;
    });

    // Train

    auto loss = std::make_shared<CrossEntropyLoss>();
    auto linearLenet = emTrainer.getTrainedModel(dataset.first, loss);

    // Eval model

    auto acc = evalModelTestAccEval(dataset.second,
                                    linearLenet,
                                    device,
                                    getDefaultCifar10TestTransform());

    std::cout << "Linear LeNet EM test accuracy: " << std::setprecision(2)
              << acc << "%" << std::endl;
}
