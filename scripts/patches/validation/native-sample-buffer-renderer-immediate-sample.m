#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>

int main(void)
{
    @autoreleasepool {
        CVPixelBufferRef pixel = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                                kCVPixelFormatType_32BGRA, NULL, &pixel) !=
            kCVReturnSuccess)
            return 10;

        CMVideoFormatDescriptionRef format = NULL;
        if (CMVideoFormatDescriptionCreateForImageBuffer(
                kCFAllocatorDefault, pixel, &format) != noErr)
            return 11;
        CMSampleTimingInfo timing = {
            .duration = kCMTimeInvalid,
            .presentationTimeStamp = kCMTimeInvalid,
            .decodeTimeStamp = kCMTimeInvalid,
        };
        CMSampleBufferRef sample = NULL;
        OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault, pixel, format, &timing, &sample);
        if (status != noErr || sample == NULL)
        {
            fprintf(stderr, "create status=%d\n", (int)status);
            return 12;
        }
        CFArrayRef attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (attachments == NULL || CFArrayGetCount(attachments) != 1)
            return 13;
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment,
                             kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
        if (!CFEqual(CFDictionaryGetValue(
                         attachment,
                         kCMSampleAttachmentKey_DisplayImmediately),
                     kCFBooleanTrue))
            return 14;
        AVSampleBufferDisplayLayer *layer =
            [AVSampleBufferDisplayLayer layer];
        AVSampleBufferVideoRenderer *renderer = layer.sampleBufferRenderer;
        [renderer enqueueSampleBuffer:sample];
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed)
        {
            fprintf(stderr, "renderer failed: %s\n",
                    renderer.error.localizedDescription.UTF8String);
            return 15;
        }
        [renderer flush];
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed)
            return 16;
        CFRelease(sample);
        CFRelease(format);
        CFRelease(pixel);
        puts("PASS immediate recovery sample construction");
    }
    return 0;
}
