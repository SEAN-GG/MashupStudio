#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and returns the NSException it raised, if any. AVAudioEngine
/// signals misuse with Objective-C exceptions that Swift cannot catch — this
/// turns them into values so the app can show an error instead of crashing.
static inline NSException * _Nullable MSCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}

NS_ASSUME_NONNULL_END
