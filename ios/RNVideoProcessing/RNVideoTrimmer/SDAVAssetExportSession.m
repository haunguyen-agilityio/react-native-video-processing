//
//  SDAVAssetExportSession.m
//
// This file is part of the SDAVAssetExportSession package.
//
// Created by Olivier Poitrey <rs@dailymotion.com> on 13/03/13.
// Copyright 2013 Olivier Poitrey. All rights servered.
//
// For the full copyright and license information, please view the LICENSE
// file that was distributed with this source code.
//


#import "SDAVAssetExportSession.h"

@interface SDAVAssetExportSession ()

@property (nonatomic, assign, readwrite) float progress;

@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderVideoCompositionOutput *videoOutput;
@property (nonatomic, strong) AVAssetReaderAudioMixOutput *audioOutput;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *videoPixelBufferAdaptor;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, strong) void (^completionHandler)();

@end

@implementation SDAVAssetExportSession
{
    NSError *_error;
    NSTimeInterval duration;
    CMTime lastSamplePresentationTime;
}

+ (id)exportSessionWithAsset:(AVAsset *)asset
{
    return [SDAVAssetExportSession.alloc initWithAsset:asset];
}

- (id)initWithAsset:(AVAsset *)asset
{
    if ((self = [super init]))
    {
        _asset = asset;
        _timeRange = CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    }

    return self;
}

- (void)exportAsynchronouslyWithCompletionHandler:(void (^)())handler
{
    NSParameterAssert(handler != nil);
    [self cancelExport];
    self.completionHandler = handler;

    if (!self.outputURL)
    {
        _error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorExportFailed userInfo:@
                  {
                  NSLocalizedDescriptionKey: @"Output URL not set"
                  }];
        handler();
        return;
    }

    NSError *readerError;
    self.reader = [AVAssetReader.alloc initWithAsset:self.asset error:&readerError];
    if (readerError)
    {
        _error = readerError;
        handler();
        return;
    }

    NSError *writerError;
    self.writer = [AVAssetWriter assetWriterWithURL:self.outputURL fileType:self.outputFileType error:&writerError];
    if (writerError)
    {
        _error = writerError;
        handler();
        return;
    }

    self.reader.timeRange = self.timeRange;
    self.writer.shouldOptimizeForNetworkUse = self.shouldOptimizeForNetworkUse;
    self.writer.metadata = self.metadata;

    NSArray *videoTracks = [self.asset tracksWithMediaType:AVMediaTypeVideo];


    if (CMTIME_IS_VALID(self.timeRange.duration) && !CMTIME_IS_POSITIVE_INFINITY(self.timeRange.duration))
    {
        duration = CMTimeGetSeconds(self.timeRange.duration);
    }
    else
    {
        duration = CMTimeGetSeconds(self.asset.duration);
    }
    //
    // Video output
    //
    if (videoTracks.count > 0) {
        self.videoOutput = [AVAssetReaderVideoCompositionOutput assetReaderVideoCompositionOutputWithVideoTracks:videoTracks videoSettings:self.videoInputSettings];
        self.videoOutput.alwaysCopiesSampleData = NO;
        if (self.videoComposition)
        {
            self.videoOutput.videoComposition = self.videoComposition;
        }
        else
        {
            self.videoOutput.videoComposition = [self buildDefaultVideoComposition];
        }
        if ([self.reader canAddOutput:self.videoOutput])
        {
            [self.reader addOutput:self.videoOutput];
        }

        //
        // Video input
        //
        self.videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:self.videoSettings];
        self.videoInput.expectsMediaDataInRealTime = NO;
        if ([self.writer canAddInput:self.videoInput])
        {
            [self.writer addInput:self.videoInput];
        }
        id pixelFormat = self.videoInputSettings[(id)kCVPixelBufferPixelFormatTypeKey];
        if (!pixelFormat) {
            pixelFormat = @(kCVPixelFormatType_32BGRA);
        }
        NSDictionary *pixelBufferAttributes = @
        {
            (id)kCVPixelBufferPixelFormatTypeKey : pixelFormat,
            //            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(self.videoOutput.videoComposition.renderSize.width),
            (id)kCVPixelBufferHeightKey: @(self.videoOutput.videoComposition.renderSize.height),
            @"IOSurfaceOpenGLESTextureCompatibility": @YES,
            @"IOSurfaceOpenGLESFBOCompatibility": @YES,
        };
        self.videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput sourcePixelBufferAttributes:pixelBufferAttributes];
    }

    //
    //Audio output
    //
    NSArray *audioTracks = [self.asset tracksWithMediaType:AVMediaTypeAudio];
    if (self.audioSettings && audioTracks.count > 0) {
        self.audioOutput = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:audioTracks audioSettings:nil];
        self.audioOutput.alwaysCopiesSampleData = NO;
        self.audioOutput.audioMix = self.audioMix;
        if ([self.reader canAddOutput:self.audioOutput])
        {
            [self.reader addOutput:self.audioOutput];
        }
    } else {
        // Just in case this gets reused
        self.audioOutput = nil;
    }

    //
    // Audio input
    //
    if (self.audioOutput) {
        self.audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:self.audioSettings];
        self.audioInput.expectsMediaDataInRealTime = NO;
        if ([self.writer canAddInput:self.audioInput])
        {
            [self.writer addInput:self.audioInput];
        }
    }

    [self.writer startWriting];
    [self.reader startReading];
    [self.writer startSessionAtSourceTime:self.timeRange.start];

    __block BOOL videoCompleted = NO;
    __block BOOL audioCompleted = NO;
    __weak typeof(self) wself = self;
    self.inputQueue = dispatch_queue_create("VideoEncoderInputQueue", DISPATCH_QUEUE_SERIAL);
    if (videoTracks.count > 0) {
        [self.videoInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
         {
             if (![wself encodeReadySamplesFromOutput:wself.videoOutput toInput:wself.videoInput])
             {
                 @synchronized(wself)
                 {
                     videoCompleted = YES;
                     if (audioCompleted)
                     {
                         [wself finish];
                     }
                 }
             }
         }];
    }
    else {
        videoCompleted = YES;
    }

    if (!self.audioOutput) {
        audioCompleted = YES;
    } else {
        [self.audioInput requestMediaDataWhenReadyOnQueue:self.inputQueue usingBlock:^
         {
             if (![wself encodeReadySamplesFromOutput:wself.audioOutput toInput:wself.audioInput])
             {
                 @synchronized(wself)
                 {
                     audioCompleted = YES;
                     if (videoCompleted)
                     {
                         [wself finish];
                     }
                 }
             }
         }];
    }
}

- (BOOL)encodeReadySamplesFromOutput:(AVAssetReaderOutput *)output toInput:(AVAssetWriterInput *)input
{
    while (input.isReadyForMoreMediaData)
    {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (sampleBuffer)
        {
            BOOL handled = NO;
            BOOL error = NO;

            if (self.reader.status != AVAssetReaderStatusReading || self.writer.status != AVAssetWriterStatusWriting)
            {
                handled = YES;
                error = YES;
            }

            if (!handled && self.videoOutput == output)
            {
                // update the video progress
                lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                lastSamplePresentationTime = CMTimeSubtract(lastSamplePresentationTime, self.timeRange.start);
                self.progress = duration == 0 ? 1 : CMTimeGetSeconds(lastSamplePresentationTime) / duration;

                if ([self.delegate respondsToSelector:@selector(exportSession:renderFrame:withPresentationTime:toBuffer:)])
                {
                    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
                    CVPixelBufferRef renderBuffer = NULL;
                    CVPixelBufferPoolCreatePixelBuffer(NULL, self.videoPixelBufferAdaptor.pixelBufferPool, &renderBuffer);
                    [self.delegate exportSession:self renderFrame:pixelBuffer withPresentationTime:lastSamplePresentationTime toBuffer:renderBuffer];
                    if (![self.videoPixelBufferAdaptor appendPixelBuffer:renderBuffer withPresentationTime:lastSamplePresentationTime])
                    {
                        error = YES;
                    }
                    CVPixelBufferRelease(renderBuffer);
                    handled = YES;
                }
            }
            if (!handled && ![input appendSampleBuffer:sampleBuffer])
            {
                error = YES;
            }
            CFRelease(sampleBuffer);

            if (error)
            {
                return NO;
            }
        }
        else
        {
            [input markAsFinished];
            return NO;
        }
    }

    return YES;
}

- (AVMutableVideoComposition *)buildDefaultVideoComposition
{
    AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
    AVAssetTrack *videoTrack = [[self.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];

    // get the frame rate from videoSettings, if not set then try to get it from the video track,
    // if not set (mainly when asset is AVComposition) then use the default frame rate of 30
    float trackFrameRate = 0;
    if (self.videoSettings)
    {
        NSDictionary *videoCompressionProperties = [self.videoSettings objectForKey:AVVideoCompressionPropertiesKey];
        if (videoCompressionProperties)
        {
            NSNumber *frameRate = [videoCompressionProperties objectForKey:AVVideoAverageNonDroppableFrameRateKey];
            if (frameRate)
            {
                trackFrameRate = frameRate.floatValue;
            }
        }
    }
    else
    {
        trackFrameRate = [videoTrack nominalFrameRate];
    }

    if (trackFrameRate == 0)
    {
        trackFrameRate = 30;
    }

    videoComposition.frameDuration = CMTimeMake(1, trackFrameRate);
    CGSize targetSize = CGSizeMake([self.videoSettings[AVVideoWidthKey] floatValue], [self.videoSettings[AVVideoHeightKey] floatValue]);
    CGSize naturalSize = [videoTrack naturalSize];

    CGAffineTransform transform = videoTrack.preferredTransform;
    CGRect rect = {{0, 0}, naturalSize};
    CGRect transformedRect = CGRectApplyAffineTransform(rect, transform);
    // transformedRect should have origin at 0 if correct; otherwise add offset to correct it
    transform.tx -= transformedRect.origin.x;
    transform.ty -= transformedRect.origin.y;
    videoComposition.frameDuration = CMTimeMake(1, trackFrameRate);

    CGFloat videoAngleInDegree  = atan2(transform.b, transform.a) * 180 / M_PI;
    if (videoAngleInDegree == 90 || videoAngleInDegree == -90) {
        CGFloat width = naturalSize.width;
        naturalSize.width = naturalSize.height;
        naturalSize.height = width;
    }

    if(transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0) {
        // portrait, home button at bottom (upright)
        if( (transform.tx == 0) && (transform.ty == 0) ) {
            transform.tx = videoTrack.naturalSize.height;
            transform.ty = 0;
        }
    }
    else if(transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0) {
        // portrait, home button at top (upside down)
        if( (transform.tx == 0) && (transform.ty == 0) ) {
            transform.tx = 0;
            transform.ty = videoTrack.naturalSize.width;
        }
    }
    else if(transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0) {
        // landscape, home button on right
        // do nothing
    }
    else if(transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0) {
        // landscape, home button on left
        if( (transform.tx == 0) && (transform.ty == 0) ) {
            transform.tx = videoTrack.naturalSize.width;
            transform.ty = videoTrack.naturalSize.height;
        }
    }
    ///////
    videoComposition.renderSize = naturalSize;
    AVMutableVideoCompositionInstruction *passThroughInstruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    passThroughInstruction.timeRange = CMTimeRangeMake(kCMTimeZero, self.asset.duration);

    AVMutableVideoCompositionLayerInstruction *passThroughLayer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];

    [passThroughLayer setTransform:transform atTime:kCMTimeZero];

    passThroughInstruction.layerInstructions = @[passThroughLayer];
    videoComposition.instructions = @[passThroughInstruction];

    return videoComposition;
}

- (void)finish
{
    // Synchronized block to ensure we never cancel the writer before calling finishWritingWithCompletionHandler
    if (self.reader.status == AVAssetReaderStatusCancelled || self.writer.status == AVAssetWriterStatusCancelled)
    {
        return;
    }

    if (self.writer.status == AVAssetWriterStatusFailed)
    {
        [self complete];
    }
    else if (self.reader.status == AVAssetReaderStatusFailed) {
        [self.writer cancelWriting];
        [self complete];
    }
    else
    {
        [self.writer finishWritingWithCompletionHandler:^
         {
             [self complete];
         }];
    }
}

- (void)complete
{
    if (self.writer.status == AVAssetWriterStatusFailed || self.writer.status == AVAssetWriterStatusCancelled)
    {
        [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
    }

    if (self.completionHandler)
    {
        self.completionHandler();
        self.completionHandler = nil;
    }
}

- (NSError *)error
{
    if (_error)
    {
        return _error;
    }
    else
    {
        return self.writer.error ? : self.reader.error;
    }
}

- (AVAssetExportSessionStatus)status
{
    switch (self.writer.status)
    {
        default:
        case AVAssetWriterStatusUnknown:
            return AVAssetExportSessionStatusUnknown;
        case AVAssetWriterStatusWriting:
            return AVAssetExportSessionStatusExporting;
        case AVAssetWriterStatusFailed:
            return AVAssetExportSessionStatusFailed;
        case AVAssetWriterStatusCompleted:
            return AVAssetExportSessionStatusCompleted;
        case AVAssetWriterStatusCancelled:
            return AVAssetExportSessionStatusCancelled;
    }
}

- (void)cancelExport
{
    if (self.inputQueue)
    {
        dispatch_async(self.inputQueue, ^
                       {
                           [self.writer cancelWriting];
                           [self.reader cancelReading];
                           [self complete];
                           [self reset];
                       });
    }
}

- (void)reset
{
    _error = nil;
    self.progress = 0;
    self.reader = nil;
    self.videoOutput = nil;
    self.audioOutput = nil;
    self.writer = nil;
    self.videoInput = nil;
    self.videoPixelBufferAdaptor = nil;
    self.audioInput = nil;
    self.inputQueue = nil;
    self.completionHandler = nil;
}

@end
