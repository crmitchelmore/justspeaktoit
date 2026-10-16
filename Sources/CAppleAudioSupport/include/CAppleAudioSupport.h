#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SPKAudioTapErrorDomain;
FOUNDATION_EXPORT NSString *const SPKAudioTapExceptionNameKey;

/// Installs a tap on `node`, returning NO with an error instead of letting the
/// Objective-C exception AVFAudio raises for an invalid tap escape. Swift cannot
/// catch that exception, so it would otherwise abort the process.
FOUNDATION_EXPORT BOOL SPKInstallAudioTap(
    AVAudioNode *node,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *_Nullable format,
    AVAudioNodeTapBlock block,
    NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
