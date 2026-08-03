#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void Fail(OSType format, const char *message)
{
    fprintf(stderr, "native PiP overlay pixel validation failed (%c%c%c%c): %s\n",
            (int)(format >> 24), (int)(format >> 16), (int)(format >> 8),
            (int)format, message);
    exit(EXIT_FAILURE);
}

static double MonotonicMilliseconds(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0)
        exit(EXIT_FAILURE);
    return value.tv_sec * 1000.0 + value.tv_nsec / 1000000.0;
}

static CVPixelBufferRef CreatePixelBuffer(OSType format, size_t width,
                                          size_t height)
{
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, format,
        (__bridge CFDictionaryRef)attributes, &buffer);
    if (status != kCVReturnSuccess)
        return NULL;
    return buffer;
}

static CGImageRef CreateOverlay(void)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        NULL, 64, 32, 8, 64 * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL)
        return NULL;
    CGContextSetRGBFillColor(context, 1.0, 0.1, 0.1, 0.8);
    CGContextFillRect(context, CGRectMake(0, 0, 64, 32));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static void ValidateFormat(CIContext *context, CGImageRef overlay,
                           CGColorSpaceRef colorSpace, OSType format,
                           size_t width, size_t height)
{
    CVPixelBufferRef source = CreatePixelBuffer(format, width, height);
    CVPixelBufferRef output = CreatePixelBuffer(format, width, height);
    if (source == NULL || output == NULL)
        Fail(format, "pixel-buffer allocation");

    CIImage *black = [[CIImage imageWithColor:
        [CIColor colorWithRed:0.02 green:0.02 blue:0.02 alpha:1.0]]
        imageByCroppingToRect:CGRectMake(0, 0, width, height)];
    [context render:black toCVPixelBuffer:source
              bounds:CGRectMake(0, 0, width, height)
          colorSpace:colorSpace];

    bool hdr = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    CVBufferSetAttachment(
        source, kCVImageBufferColorPrimariesKey,
        hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
            : kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(
        source, kCVImageBufferTransferFunctionKey,
        hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            : kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(
        source, kCVImageBufferYCbCrMatrixKey,
        hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020
            : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CFDictionaryRef expectedAttachments =
        CVBufferCopyAttachments(source, kCVAttachmentMode_ShouldPropagate);

    CIImage *result = [CIImage imageWithCVPixelBuffer:source];
    CIImage *region = [CIImage imageWithCGImage:overlay];
    CGAffineTransform transform = CGAffineTransformMakeScale(3.0, 3.0);
    transform.tx = (CGFloat)(width - 192) / 2.0;
    transform.ty = (CGFloat)(height - 96) / 2.0;
    region = [region imageByApplyingTransform:transform];
    result = [region imageByCompositingOverImage:result];
    CGColorSpaceRef renderColorSpace = CVImageBufferGetColorSpace(source);
    if (renderColorSpace == NULL)
        renderColorSpace = colorSpace;

    double durations[2];
    for (size_t iteration = 0; iteration < 2; ++iteration) {
        double before = MonotonicMilliseconds();
        @try {
            [context render:result toCVPixelBuffer:output
                      bounds:CGRectMake(0, 0, width, height)
                  colorSpace:renderColorSpace];
        } @catch (NSException *exception) {
            (void)exception;
            Fail(format, "Core Image render");
        }
        durations[iteration] = MonotonicMilliseconds() - before;
    }

    CVBufferRemoveAllAttachments(output);
    CVBufferSetAttachments(output, expectedAttachments,
                           kCVAttachmentMode_ShouldPropagate);
    CFDictionaryRef actualAttachments =
        CVBufferCopyAttachments(output, kCVAttachmentMode_ShouldPropagate);
    if (actualAttachments == NULL ||
        !CFEqual(expectedAttachments, actualAttachments))
        Fail(format, "decoder attachments were not preserved");
    if (CVPixelBufferGetPixelFormatType(output) != format ||
        CVPixelBufferGetWidth(output) != width ||
        CVPixelBufferGetHeight(output) != height)
        Fail(format, "output format or dimensions changed");

    CGImageRef rendered = [context createCGImage:
        [CIImage imageWithCVPixelBuffer:output]
                                      fromRect:CGRectMake(transform.tx,
                                                          transform.ty,
                                                          192, 96)];
    if (rendered == NULL)
        Fail(format, "composited region could not be read back");
    printf("%c%c%c%c,%zux%zu,cold=%.3fms,warm=%.3fms\n",
           (int)(format >> 24), (int)(format >> 16),
           (int)(format >> 8), (int)format, width, height,
           durations[0], durations[1]);

    CGImageRelease(rendered);
    CFRelease(actualAttachments);
    CFRelease(expectedAttachments);
    CVPixelBufferRelease(output);
    CVPixelBufferRelease(source);
}

int main(void)
{
    @autoreleasepool {
        CIContext *context = [CIContext contextWithOptions:@{
            kCIContextCacheIntermediates: @NO,
        }];
        CGImageRef overlay = CreateOverlay();
        CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (overlay == NULL || colorSpace == NULL)
            Fail(0, "test image setup");

        const OSType formats[] = {
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_64RGBAHalf,
        };
        for (size_t index = 0; index < sizeof(formats) / sizeof(formats[0]);
             ++index)
            ValidateFormat(context, overlay, colorSpace, formats[index],
                           640, 360);
        ValidateFormat(context, overlay, colorSpace,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       1920, 1080);
        ValidateFormat(context, overlay, colorSpace,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       3840, 2160);

        CGColorSpaceRelease(colorSpace);
        CGImageRelease(overlay);
    }
    puts("native PiP overlay pixel validation passed");
    return EXIT_SUCCESS;
}
