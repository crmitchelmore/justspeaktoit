#import "CAppleAudioSupport.h"

NSErrorDomain const SPKAudioTapErrorDomain = @"com.justspeaktoit.audio-tap";
NSString *const SPKAudioTapExceptionNameKey = @"SPKAudioTapExceptionName";

BOOL SPKInstallAudioTap(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock block,
    NSError *_Nullable *_Nullable error) {
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // The macOS/iOS 27 error-returning variant still raises for some
        // invalid states, and older systems only have this one, so a single
        // guarded call covers every supported OS.
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
#pragma clang diagnostic pop
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:SPKAudioTapErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedFailureReasonErrorKey: reason,
                                         SPKAudioTapExceptionNameKey: exception.name
                                     }];
        }
        return NO;
    }
}
