#import "Voice.h"
#import <Accelerate/Accelerate.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <Speech/Speech.h>
#import <UIKit/UIKit.h>

@interface Voice () <SFSpeechRecognizerDelegate>

@property(nonatomic) SFSpeechRecognizer *speechRecognizer;
@property(nonatomic) SFSpeechURLRecognitionRequest *recognitionUrlRequest;
@property(nonatomic) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property(nonatomic) AVAudioEngine *audioEngine;
@property(nonatomic) SFSpeechRecognitionTask *recognitionTask;
@property(nonatomic) AVAudioSession *audioSession;
/** Whether speech recognition is finishing.. */
@property(nonatomic) BOOL isTearingDown;
@property(nonatomic) BOOL continuous;

@property(nonatomic) NSString *sessionId;
/** Previous category the user was on prior to starting speech recognition */
@property(nonatomic) NSString *priorAudioCategory;
/** Volume level Metering*/
@property float averagePowerForChannel0;
@property float averagePowerForChannel1;

@end

@implementation Voice {
}



///** Returns "YES" if no errors had occurred */
- (BOOL)setupAudioSession {
  NSError *categoryError = nil;

  // Set optimal audio session configuration for speech recognition
  if ([self isHeadsetPluggedIn] || [self isHeadSetBluetooth]) {
    [self.audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                       withOptions:AVAudioSessionCategoryOptionAllowBluetooth |
                                   AVAudioSessionCategoryOptionMixWithOthers
                             error:&categoryError];
  } else {
    [self.audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                       withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                   AVAudioSessionCategoryOptionMixWithOthers
                             error:&categoryError];
  }

  if (categoryError != nil) {
    NSLog(@"[Voice] Failed to set audio session category: %@", [categoryError localizedDescription]);
    [self sendResult:@{
      @"code" : @"audio_category_error",
      @"message" : [categoryError localizedDescription]
    }:nil:nil:nil];
    return NO;
  }

  // Set preferred sample rate and buffer duration for better performance
  NSError *sampleRateError = nil;
  [self.audioSession setPreferredSampleRate:16000.0 error:&sampleRateError];
  if (sampleRateError != nil) {
    NSLog(@"[Voice] Warning: Failed to set preferred sample rate: %@", [sampleRateError localizedDescription]);
    // Continue anyway, this is not critical
  }

  NSError *bufferDurationError = nil;
  [self.audioSession setPreferredIOBufferDuration:0.02 error:&bufferDurationError]; // 20ms buffer
  if (bufferDurationError != nil) {
    NSLog(@"[Voice] Warning: Failed to set buffer duration: %@", [bufferDurationError localizedDescription]);
    // Continue anyway, this is not critical
  }

  NSError *audioSessionError = nil;

  // Activate the audio session
  [self.audioSession
        setActive:YES
      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:&audioSessionError];

  if (audioSessionError != nil) {
    [self sendResult:@{
      @"code" : @"audio",
      @"message" : [audioSessionError localizedDescription]
    }:nil:nil:nil];
    return NO;
  }

  // Add a small delay to ensure audio hardware is fully ready
  // This is especially important for first-time authorization
  [NSThread sleepForTimeInterval:0.1];
  NSLog(@"[Voice] Audio session activated with delay");

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(teardown)
             name:RCTBridgeWillReloadNotification
           object:nil];

  return YES;
}

    - (BOOL)isHeadsetPluggedIn {
  AVAudioSessionRouteDescription *route =
      [[AVAudioSession sharedInstance] currentRoute];
  for (AVAudioSessionPortDescription *desc in [route outputs]) {
    if ([[desc portType] isEqualToString:AVAudioSessionPortHeadphones] ||
        [[desc portType] isEqualToString:AVAudioSessionPortBluetoothA2DP])
      return YES;
  }
  return NO;
}

    - (BOOL)isHeadSetBluetooth {
  NSArray *arrayInputs = [[AVAudioSession sharedInstance] availableInputs];
  for (AVAudioSessionPortDescription *port in arrayInputs) {
    if ([port.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
      return YES;
    }
  }
  return NO;
}

- (void)teardown {
  self.isTearingDown = YES;
  [self.recognitionTask cancel];
  self.recognitionTask = nil;

  // Set back audio session category
  [self resetAudioSession];

  // End recognition request
  [self.recognitionRequest endAudio];

  // Remove tap on bus
  [self.audioEngine.inputNode removeTapOnBus:0];
  [self.audioEngine.inputNode reset];

  // Stop audio engine and dereference it for re-allocation
  if (self.audioEngine.isRunning) {
    [self.audioEngine stop];
    [self.audioEngine reset];
    self.audioEngine = nil;
  }

  self.recognitionRequest = nil;
  self.recognitionUrlRequest = nil;
  self.sessionId = nil;
  self.isTearingDown = NO;
}

- (void)resetAudioSession {
  if (self.audioSession == nil) {
    self.audioSession = [AVAudioSession sharedInstance];
  }
  // Set audio session to inactive and notify other sessions
  // [self.audioSession setActive:NO
  // withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:
  // nil];
  NSString *audioCategory = [self.audioSession category];
  // Category hasn't changed -- do nothing
  if ([self.priorAudioCategory isEqualToString:audioCategory])
    return;
  // Reset back to the previous category
  if ([self isHeadsetPluggedIn] || [self isHeadSetBluetooth]) {
    [self.audioSession setCategory:self.priorAudioCategory
                       withOptions:AVAudioSessionCategoryOptionAllowBluetooth
                             error:nil];
  } else {
    [self.audioSession setCategory:self.priorAudioCategory
                       withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                             error:nil];
  }
  // Remove pointer reference
  self.audioSession = nil;
}

- (void)setupAndTranscribeFile:(NSString *)filePath
                 withLocaleStr:(NSString *)localeStr {

  // Tear down resources before starting speech recognition..
  [self teardown];

  self.sessionId = [[NSUUID UUID] UUIDString];

  NSLocale *locale = nil;
  if ([localeStr length] > 0) {
    locale = [NSLocale localeWithLocaleIdentifier:localeStr];
  }

  if (locale) {
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
  } else {
    self.speechRecognizer = [[SFSpeechRecognizer alloc] init];
  }

  self.speechRecognizer.delegate = self;

  [self sendEventWithName:@"onTranscriptionError"
                     body:@{
                       @"error" :
                           @{@"code" : @"fake_error", @"message" : filePath}
                     }];
  // Set up recognition request
  self.recognitionUrlRequest = [[SFSpeechURLRecognitionRequest alloc]
      initWithURL:[NSURL fileURLWithPath:filePath]];

  if (self.recognitionUrlRequest == nil) {
    [self sendEventWithName:@"onTranscriptionError"
                       body:@{@"error" : @{@"code" : @"recognition_url_init"}}];
    [self teardown];
    return;
  }

  @try {

    [self sendEventWithName:@"onTranscriptionStart" body:nil];

    // Set up recognition task
    // A recognition task represents a speech recognition session.
    // We keep a reference to the task so that it can be cancelled.
    NSString *taskSessionId = self.sessionId;
    self.recognitionTask = [self.speechRecognizer
        recognitionTaskWithRequest:self.recognitionUrlRequest
                     resultHandler:^(
                         SFSpeechRecognitionResult *_Nullable result,
                         NSError *_Nullable error) {
                       if (![taskSessionId isEqualToString:self.sessionId]) {
                         // session ID has changed, so ignore any capture
                         // results and error
                         [self teardown];
                         return;
                       }
                       if (error != nil) {
                         NSString *errorMessage = [NSString
                             stringWithFormat:@"%ld/%@", error.code,
                                              [error localizedDescription]];

                         [self sendEventWithName:@"onTranscriptionError"
                                            body:@{
                                              @"error" : @{
                                                @"code" : @"recognition_fail_o",
                                                @"message" : errorMessage,
                                                @"filePath" : filePath
                                              }
                                            }];
                         [self teardown];
                         return;
                       }
                       // No result.
                       if (result == nil) {
                         [self sendEventWithName:@"onTranscriptionEnd"
                                            body:nil];
                         [self teardown];
                         return;
                       }

                       BOOL isFinal = result.isFinal;

                       if (isFinal) {
                         NSMutableArray *transcriptionSegs =
                             [NSMutableArray new];
                         for (SFTranscriptionSegment *segment in result
                                  .bestTranscription.segments) {
                           [transcriptionSegs addObject:@{
                             @"transcription" : segment.substring,
                             @"timestamp" : @(segment.timestamp),
                             @"duration" : @(segment.duration)
                           }];
                         }

                         [self sendEventWithName:@"onTranscriptionResults"
                                            body:@{
                                              @"segments" : transcriptionSegs,
                                              @"transcription" :
                                                  result.bestTranscription
                                                      .formattedString,
                                              @"isFinal" : @(isFinal)
                                            }];
                       }

                       if (isFinal || self.recognitionTask.isCancelled ||
                           self.recognitionTask.isFinishing) {
                         [self sendEventWithName:@"onTranscriptionEnd"
                                            body:nil];
                         [self teardown];
                         return;
                       }
                     }];
  } @catch (NSException *exception) {
    [self sendEventWithName:@"onTranscriptionError"
                       body:@{
                         @"error" : @{
                           @"code" : @"start_transcription_fail",
                           @"message" : [exception reason]
                         }
                       }];
    [self teardown];

    return;
  } @finally {
  }
}

- (void)setupAndStartRecognizing:(NSString *)localeStr {
 NSLog(@"[Voice] Starting speech recognition setup with locale: %@", localeStr);

 self.audioSession = [AVAudioSession sharedInstance];
 self.priorAudioCategory = [self.audioSession category];
 NSLog(@"[Voice] Audio session category: %@", self.priorAudioCategory);

 // Tear down resources before starting speech recognition..
 [self teardown];

 self.sessionId = [[NSUUID UUID] UUIDString];
 NSLog(@"[Voice] Session ID: %@", self.sessionId);

 NSLocale *locale = nil;
 if ([localeStr length] > 0) {
   locale = [NSLocale localeWithLocaleIdentifier:localeStr];
 }

 if (locale) {
   self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
 } else {
   self.speechRecognizer = [[SFSpeechRecognizer alloc] init];
 }

 self.speechRecognizer.delegate = self;

 // Start audio session...
 NSLog(@"[Voice] Setting up audio session...");
 if (![self setupAudioSession]) {
   NSLog(@"[Voice] Failed to setup audio session");
   [self teardown];
   return;
 }
 NSLog(@"[Voice] Audio session setup completed");

 self.recognitionRequest =
     [[SFSpeechAudioBufferRecognitionRequest alloc] init];
 // Configure request so that results are returned before audio
 // recording is finished
 self.recognitionRequest.shouldReportPartialResults = YES;

 if (self.recognitionRequest == nil) {
   [self sendResult:@{@"code" : @"recognition_init"}:nil:nil:nil];
   [self teardown];
   return;
 }

 if (self.audioEngine == nil) {
   self.audioEngine = [[AVAudioEngine alloc] init];
   NSLog(@"[Voice] Created new audio engine");
 } else {
   NSLog(@"[Voice] Reusing existing audio engine");
 }

 @try {
   AVAudioInputNode *inputNode = self.audioEngine.inputNode;
   if (inputNode == nil) {
     NSLog(@"[Voice] Failed to get input node");
     [self sendResult:@{@"code" : @"input"}:nil:nil:nil];
     [self teardown];
     return;
   }
   NSLog(@"[Voice] Got input node successfully");

   [self sendEventWithName:@"onSpeechStart" body:nil];
   NSLog(@"[Voice] Sent onSpeechStart event");

   // A recognition task represents a speech recognition session.
   // We keep a reference to the task so that it can be cancelled.
   NSString *taskSessionId = self.sessionId;
   self.recognitionTask = [self.speechRecognizer
       recognitionTaskWithRequest:self.recognitionRequest
                    resultHandler:^(
                        SFSpeechRecognitionResult *_Nullable result,
                        NSError *_Nullable error) {
                      if (![taskSessionId isEqualToString:self.sessionId]) {
                        // session ID has changed, so ignore any
                        // capture results and error
                        [self teardown];
                        return;
                      }
                      if (error != nil) {
                        NSString *errorMessage = [NSString
                            stringWithFormat:@"%ld/%@", error.code,
                                             [error localizedDescription]];
                        [self sendResult:@{
                          @"code" : @"recognition_fail_ooo",
                          @"message" : errorMessage
                        }:nil:nil:nil];
                        [self teardown];
                        return;
                      }

                      // No result.
                      if (result == nil) {
                        [self sendEventWithName:@"onSpeechEnd" body:nil];
                        [self teardown];
                        return;
                      }

                      BOOL isFinal = result.isFinal;

                      NSMutableArray *transcriptionDics = [NSMutableArray new];
                      for (SFTranscription *transcription in result
                               .transcriptions) {
                        [transcriptionDics
                            addObject:transcription.formattedString];
                      }

                      [self sendResult :nil :result.bestTranscription.formattedString :transcriptionDics :[NSNumber numberWithBool:isFinal]];

                      if (isFinal || self.recognitionTask.isCancelled ||
                          self.recognitionTask.isFinishing) {
                        [self sendEventWithName:@"onSpeechEnd" body:nil];
                        if (!self.continuous) {
                          [self teardown];
                        }
                        return;
                      }
                    }];

            // Always use a reliable format instead of trying to get from hardware
   // This avoids hardware compatibility issues on different devices
   NSLog(@"[Voice] Creating reliable audio format for speech recognition");

   AVAudioFormat *recordingFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                     sampleRate:16000.0
                                                                       channels:1
                                                                    interleaved:YES];

   if (recordingFormat == nil) {
     NSLog(@"[Voice] Failed to create common format, trying standard format");
     recordingFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000.0 channels:1];
   }

   if (recordingFormat == nil) {
     NSLog(@"[Voice] Failed to create any audio format");
     [self sendResult:@{
       @"code" : @"audio_format_creation_failed",
       @"message" : @"Unable to create audio format"
     }:nil:nil:nil];
     [self teardown];
     return;
   }

   NSLog(@"[Voice] Created audio format: sampleRate=%.1f, channels=%d, format=%@",
         recordingFormat.sampleRate,
         recordingFormat.channelCount,
         recordingFormat.formatDescription);

   // Final validation before using the format
   if (recordingFormat == nil) {
     NSLog(@"[Voice] Critical error: recordingFormat is nil after all fallbacks");
     [self sendResult:@{
       @"code" : @"audio_format_error",
       @"message" : @"Failed to create valid audio format"
     }:nil:nil:nil];
     [self teardown];
     return;
   }

   AVAudioMixerNode *mixer = [[AVAudioMixerNode alloc] init];
   [self.audioEngine attachNode:mixer];
   NSLog(@"[Voice] Attached mixer node to audio engine");

   // Start recording and append recording buffer to speech recognizer
   NSLog(@"[Voice] Installing tap on mixer with format: sampleRate=%.1f, channels=%d",
         recordingFormat.sampleRate, recordingFormat.channelCount);
   @try {
     [mixer
         installTapOnBus:0
              bufferSize:1024
                  format:recordingFormat
                   block:^(AVAudioPCMBuffer *_Nonnull buffer,
                           AVAudioTime *_Nonnull when) {
                     // Volume Level Metering
                     UInt32 inNumberFrames = buffer.frameLength;
                     float LEVEL_LOWPASS_TRIG = 0.5;
                     if (buffer.format.channelCount > 0) {
                       Float32 *samples =
                           (Float32 *)buffer.floatChannelData[0];
                       Float32 avgValue = 0;

                       vDSP_maxmgv((Float32 *)samples, 1, &avgValue,
                                   inNumberFrames);
                       self.averagePowerForChannel0 =
                           (LEVEL_LOWPASS_TRIG *
                            ((avgValue == 0) ? -100
                                             : 20.0 * log10f(avgValue))) +
                           ((1 - LEVEL_LOWPASS_TRIG) *
                            self.averagePowerForChannel0);
                       self.averagePowerForChannel1 =
                           self.averagePowerForChannel0;
                     }

                     if (buffer.format.channelCount > 1) {
                       Float32 *samples =
                           (Float32 *)buffer.floatChannelData[1];
                       Float32 avgValue = 0;

                       vDSP_maxmgv((Float32 *)samples, 1, &avgValue,
                                   inNumberFrames);
                       self.averagePowerForChannel1 =
                           (LEVEL_LOWPASS_TRIG *
                            ((avgValue == 0) ? -100
                                             : 20.0 * log10f(avgValue))) +
                           ((1 - LEVEL_LOWPASS_TRIG) *
                            self.averagePowerForChannel1);
                     }
                     // Normalizing the Volume Value on scale of (0-10)
                     self.averagePowerForChannel1 =
                         [self _normalizedPowerLevelFromDecibels:
                                   self.averagePowerForChannel1] *
                         10;
                     NSNumber *value = [NSNumber
                         numberWithFloat:self.averagePowerForChannel1];
                     [self sendEventWithName:@"onSpeechVolumeChanged"
                                        body:@{@"value" : value}];

                     // Todo: write recording buffer to file (if user
                     // opts in)
                     if (self.recognitionRequest != nil) {
                       [self.recognitionRequest appendAudioPCMBuffer:buffer];
                     }
                   }];
     } @catch (NSException *exception) {
       NSLog(@"[Error] - %@ %@", exception.name, exception.reason);
       [self sendResult:@{
         @"code" : @"start_recording",
         @"message" : [exception reason]
       }:nil:nil:nil];
       [self teardown];
       return;
     } @finally {
     }

          NSLog(@"[Voice] Connecting audio nodes...");

     // Get current input node format - we MUST use this for connection
     AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
     NSLog(@"[Voice] Input node format: sampleRate=%.1f, channels=%d",
           inputFormat ? inputFormat.sampleRate : 0,
           inputFormat ? inputFormat.channelCount : 0);

     // Validate input format
     if (inputFormat == nil || inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0) {
       NSLog(@"[Voice] Invalid input node format, cannot connect");
       [self sendResult:@{
         @"code" : @"invalid_input_format",
         @"message" : @"Audio input format is invalid"
       }:nil:nil:nil];
       [self teardown];
       return;
     }

     // Connect using the input node's native format (not our recording format)
     // This is critical - the connection must use compatible formats
     [self.audioEngine connect:inputNode to:mixer format:inputFormat];
     NSLog(@"[Voice] Connected input node to mixer with input format: sampleRate=%.1f, channels=%d",
           inputFormat.sampleRate, inputFormat.channelCount);
     NSLog(@"[Voice] Tap will use recording format: sampleRate=%.1f, channels=%d",
           recordingFormat.sampleRate, recordingFormat.channelCount);

     NSLog(@"[Voice] Preparing audio engine...");
     [self.audioEngine prepare];

     NSLog(@"[Voice] Starting audio engine...");
     NSError *audioSessionError = nil;
     [self.audioEngine startAndReturnError:&audioSessionError];
     if (audioSessionError != nil) {
       NSLog(@"[Voice] Audio engine start failed: %@", [audioSessionError localizedDescription]);
       [self sendResult:@{
         @"code" : @"audio",
         @"message" : [audioSessionError localizedDescription]
       }:nil:nil:nil];
       [self teardown];
       return;
     }
     NSLog(@"[Voice] Audio engine started successfully");
 } @catch (NSException *exception) {
   [self sendResult:@{
     @"code" : @"start_recording",
     @"message" : [exception reason]
   }:nil:nil:nil];
   return;
 }
}

- (CGFloat)_normalizedPowerLevelFromDecibels:(CGFloat)decibels {
  if (decibels < -80.0f || decibels == 0.0f) {
    return 0.0f;
  }
  CGFloat power =
      powf((powf(10.0f, 0.05f * decibels) - powf(10.0f, 0.05f * -80.0f)) *
               (1.0f / (1.0f - powf(10.0f, 0.05f * -80.0f))),
           1.0f / 2.0f);
  if (power < 1.0f) {
    return power;
  } else {
    return 1.0f;
  }
}

- (NSArray<NSString *> *)supportedEvents {
  return @[
    @"onSpeechResults", @"onSpeechStart", @"onSpeechPartialResults",
    @"onSpeechError", @"onSpeechEnd", @"onSpeechRecognized",
    @"onSpeechVolumeChanged", @"onTranscriptionStart", @"onTranscriptionEnd",
    @"onTranscriptionError", @"onTranscriptionResults"
  ];
}

- (void)sendResult:(NSDictionary *)
             error:(NSString *)bestTranscription
                  :(NSArray *)transcriptions
                  :(NSNumber *)isFinal {
  if (error != nil) {
    [self sendEventWithName:@"onSpeechError" body:@{@"error" : error}];
  }
  if (bestTranscription != nil) {
    [self sendEventWithName:@"onSpeechResults"
                       body:@{@"value" : @[ bestTranscription ]}];
  }
  if (transcriptions != nil) {
    [self sendEventWithName:@"onSpeechPartialResults"
                       body:@{@"value" : transcriptions}];
  }
  if (isFinal != nil) {
    [self sendEventWithName:@"onSpeechRecognized" body:@{@"isFinal" : isFinal}];
  }
}

// Called when the availability of the given recognizer changes
- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer
    availabilityDidChange:(BOOL)available {
  if (available == false) {
    [self sendResult:RCTMakeError(@"Speech recognition is not available now",
                                  nil, nil):nil:nil:nil];
  }
}

RCT_EXPORT_METHOD(stopSpeech : (RCTResponseSenderBlock)callback) {
  [self.recognitionTask finish];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(stopTranscription : (RCTResponseSenderBlock)callback) {
  [self.recognitionTask finish];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(cancelSpeech : (RCTResponseSenderBlock)callback) {
  [self.recognitionTask cancel];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(cancelTranscription : (RCTResponseSenderBlock)callback) {
  [self.recognitionTask cancel];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(destroySpeech : (RCTResponseSenderBlock)callback) {
  [self teardown];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(destroyTranscription : (RCTResponseSenderBlock)callback) {
  [self teardown];
  callback(@[ @false ]);
}

RCT_EXPORT_METHOD(isSpeechAvailable : (RCTResponseSenderBlock)callback) {
  [SFSpeechRecognizer
      requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
    switch (status) {
      case SFSpeechRecognizerAuthorizationStatusAuthorized:
          callback(@[ @true ]);
        break;
      default:
          callback(@[ @false ]);
    }
  }];
}
RCT_EXPORT_METHOD(isRecognizing : (RCTResponseSenderBlock)callback) {
 if (self.recognitionTask != nil) {
   switch (self.recognitionTask.state) {
   case SFSpeechRecognitionTaskStateRunning:
     callback(@[ @true ]);
     break;
   default:
     callback(@[ @false ]);
   }
 } else {
   callback(@[ @false ]);
 }
}

RCT_EXPORT_METHOD(startSpeech
                 : (NSString *)localeStr callback
                 : (RCTResponseSenderBlock)callback) {
 if (self.recognitionTask != nil) {
   [self sendResult:RCTMakeError(@"Speech recognition already started!", nil,
                                 nil):nil:nil:nil];
   return;
 }

  [SFSpeechRecognizer requestAuthorization:^(
                         SFSpeechRecognizerAuthorizationStatus status) {
   switch (status) {
   case SFSpeechRecognizerAuthorizationStatusNotDetermined:
     [self sendResult:RCTMakeError(@"Speech recognition not yet authorized",
                                   nil, nil):nil:nil:nil];
     break;
   case SFSpeechRecognizerAuthorizationStatusDenied:
     [self sendResult:RCTMakeError(@"User denied access to speech recognition",
                                   nil, nil):nil:nil:nil];
     break;
   case SFSpeechRecognizerAuthorizationStatusRestricted:
     [self sendResult:RCTMakeError(
                          @"Speech recognition restricted on this device", nil,
                          nil):nil:nil:nil];
     break;
   case SFSpeechRecognizerAuthorizationStatusAuthorized:
     [self setupAndStartRecognizing:localeStr];
     break;
   }
 }];
 callback(@[ @false ]);
}

RCT_EXPORT_METHOD(startTranscription
                  : (NSString *)filePath withLocaleStr
                  : (NSString *)localeStr callback
                  : (RCTResponseSenderBlock)callback) {
  if (self.recognitionTask != nil) {
    [self sendResult:RCTMakeError(@"Speech recognition already started!", nil,
                                  nil):nil:nil:nil];
    return;
  }

  [SFSpeechRecognizer requestAuthorization:^(
                          SFSpeechRecognizerAuthorizationStatus status) {
    switch (status) {
    case SFSpeechRecognizerAuthorizationStatusNotDetermined:
      [self sendResult:RCTMakeError(@"Speech recognition not yet authorized",
                                    nil, nil):nil:nil:nil];
      break;
    case SFSpeechRecognizerAuthorizationStatusDenied:
      [self sendResult:RCTMakeError(@"User denied access to speech recognition",
                                    nil, nil):nil:nil:nil];
      break;
    case SFSpeechRecognizerAuthorizationStatusRestricted:
      [self sendResult:RCTMakeError(
                           @"Speech recognition restricted on this device", nil,
                           nil):nil:nil:nil];
      break;
    case SFSpeechRecognizerAuthorizationStatusAuthorized:
      [self setupAndTranscribeFile:filePath withLocaleStr:localeStr];
      break;
    }
  }];
  callback(@[ @false ]);
}
 


+ (BOOL)requiresMainQueueSetup {
    return YES;
}

// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeVoiceIOSSpecJSI>(params);
}
#endif

- (dispatch_queue_t)methodQueue {
  return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()


@end
