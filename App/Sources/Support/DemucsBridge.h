#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DemucsProgress)(float progress);

/// Objective-C++ bridge to demucs.cpp (AI source separation). When the C++
/// sources aren't present (local builds without scripts/build_demucs.sh),
/// `isCompiledIn` returns NO and separation reports itself unavailable.
@interface DemucsBridge : NSObject

+ (BOOL)isCompiledIn;

/// Separates stereo 44.1 kHz audio into stems using an htdemucs ggml model.
/// Returns one NSData per source in the model's order (6-source:
/// drums, bass, other, vocals, guitar, piano). Each blob holds `frames`
/// floats of the left channel followed by `frames` floats of the right.
/// Returns nil on failure (bad model file / not compiled in / empty input).
+ (nullable NSArray<NSData *> *)separateWithModelPath:(NSString *)modelPath
                                                 left:(const float *)left
                                                right:(const float *)right
                                               frames:(int64_t)frames
                                             progress:(nullable DemucsProgress)progress;

/// Frees the cached model weights (call when a separation job finishes).
+ (void)unloadModel;

@end

NS_ASSUME_NONNULL_END
