#import "DemucsBridge.h"

#if __has_include("model.hpp")
#define DEMUCS_AVAILABLE 1
#include "model.hpp"
#include "tensor.hpp"
#include <Eigen/Dense>
#include <memory>
#include <mutex>
#include <string>
#endif

#if DEMUCS_AVAILABLE
static std::unique_ptr<demucscpp::demucs_model> gModel;
static std::string gModelPath;
static std::mutex gModelMutex;
#endif

@implementation DemucsBridge

+ (BOOL)isCompiledIn {
#if DEMUCS_AVAILABLE
    return YES;
#else
    return NO;
#endif
}

+ (nullable NSArray<NSData *> *)separateWithModelPath:(NSString *)modelPath
                                                 left:(const float *)left
                                                right:(const float *)right
                                               frames:(int64_t)frames
                                             progress:(nullable DemucsProgress)progress {
#if DEMUCS_AVAILABLE
    if (frames <= 0) {
        return nil;
    }
    std::lock_guard<std::mutex> lock(gModelMutex);

    std::string path = modelPath.UTF8String;
    if (!gModel || gModelPath != path) {
        auto model = std::make_unique<demucscpp::demucs_model>();
        if (!demucscpp::load_demucs_model(path, model.get())) {
            return nil;
        }
        gModel = std::move(model);
        gModelPath = path;
    }

    Eigen::MatrixXf audio(2, (Eigen::Index)frames);
    for (int64_t i = 0; i < frames; ++i) {
        audio(0, (Eigen::Index)i) = left[i];
        audio(1, (Eigen::Index)i) = right[i];
    }

    demucscpp::ProgressCallback callback = [progress](float p, const std::string &) {
        if (progress) progress(p);
    };

    Eigen::Tensor3dXf out = demucscpp::demucs_inference(*gModel, audio, callback);

    const int sourceCount = (int)out.dimension(0);
    const int64_t outFrames = (int64_t)out.dimension(2);
    const int64_t n = outFrames < frames ? outFrames : frames;

    NSMutableArray<NSData *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)sourceCount];
    for (int s = 0; s < sourceCount; ++s) {
        NSMutableData *blob = [NSMutableData dataWithLength:(NSUInteger)(frames * 2 * sizeof(float))];
        float *ptr = (float *)blob.mutableBytes;
        for (int64_t i = 0; i < n; ++i) {
            ptr[i] = out(s, 0, (Eigen::Index)i);
            ptr[frames + i] = out(s, 1, (Eigen::Index)i);
        }
        [result addObject:blob];
    }
    return result;
#else
    (void)modelPath; (void)left; (void)right; (void)frames; (void)progress;
    return nil;
#endif
}

+ (void)unloadModel {
#if DEMUCS_AVAILABLE
    std::lock_guard<std::mutex> lock(gModelMutex);
    gModel.reset();
    gModelPath.clear();
#endif
}

@end
