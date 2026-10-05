// Sing's separator: two seconds of a song in, its vocals out, through the voice model (Mel-Band RoFormer
// with KimberleyJensen's vocal checkpoint, MIT; Sing.h says where it comes from). The model is the spectral
// core only, so the STFT around it is done here, as the checkpoint's reference implementation does it
// (its configs/config_vocals_mel_band_roformer.yaml, and model.mil read for the layout):
//
//   44.1 kHz stereo, n_fft 2048, hop 441, a periodic Hann window of 2048, unnormalized, centred with
//   reflect padding (torch.stft's defaults), so two seconds (88200 frames) make 201 frames of 1025 bins.
//   The model's `spectrum` and `vocals_spectrum` are float32 [1, 2050, 201, 2]: axis 1 is bin-major with
//   the two channels interleaved (bin f of channel c at 2f + c, which its band split's gather indices
//   pair up), the last axis real then imaginary (its complex mask multiply reads them so).
//
// The vocals come back from the model's complex mask times the spectrum, through the inverse STFT
// (torch.istft: overlap-add of the windowed frames divided by the window's squared sum).
//
// Threading: one separator is used by one thread at a time (its buffers are its own).
#import <Foundation/Foundation.h>

@class MLModel;

enum {
    kSGSingRate = 44100,
    kSGSingWindowFrames = 88200,   // two seconds, what the model takes
    kSGSingFFT = 2048,
    kSGSingHop = 441,
    kSGSingBins = kSGSingFFT / 2 + 1,
    kSGSingSTFTFrames = kSGSingWindowFrames / kSGSingHop + 1,
    kSGSingSpectrumFloats = kSGSingBins * 2 * kSGSingSTFTFrames * 2,
};

@interface SGSingSeparator : NSObject
// Nil `model` makes one that only does the STFT, for the harness.
- (instancetype)initWithModel:(MLModel *)model;
// The window's spectrum in the model's layout, `spectrum` holding kSGSingSpectrumFloats.
- (void)analyzeLeft:(const float *)left right:(const float *)right into:(float *)spectrum;
// The inverse: kSGSingWindowFrames frames per channel out of a spectrum in the model's layout.
- (void)synthesize:(const float *)spectrum left:(float *)left right:(float *)right;
// The vocals of kSGSingWindowFrames frames of stereo; NO and `error` when the model failed.
- (BOOL)separateLeft:(const float *)left right:(const float *)right vocalsLeft:(float *)vocalsLeft
         vocalsRight:(float *)vocalsRight error:(NSError **)error;
@end
