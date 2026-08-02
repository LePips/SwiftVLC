#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "VLCSampleBufferFormatDescriptionCache.h"

#include <stdio.h>
#include <stdlib.h>

static void Require(bool condition, const char *message)
{
    if (condition)
        return;
    fprintf(stderr, "native format-description cache validation failed: %s\n",
            message);
    exit(EXIT_FAILURE);
}

static CVPixelBufferRef MakePixelBuffer(size_t width, size_t height,
                                        OSType pixelFormat,
                                        CFStringRef colourPrimaries)
{
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          pixelFormat, NULL, &buffer);
    Require(status == kCVReturnSuccess && buffer != NULL,
            "CVPixelBufferCreate");
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          colourPrimaries,
                          kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static CMVideoFormatDescriptionRef
CopyDescription(vlc_samplebuffer_format_description_cache *cache,
                CVPixelBufferRef buffer, bool expectedReuse)
{
    CMVideoFormatDescriptionRef description = NULL;
    bool reused = !expectedReuse;
    OSStatus status = vlc_samplebuffer_format_description_cache_Copy(
        cache, buffer, &description, &reused);
    Require(status == noErr && description != NULL, "description creation");
    Require(reused == expectedReuse, expectedReuse
        ? "compatible buffer was not reused"
        : "incompatible buffer incorrectly reused the cache");
    Require(CMVideoFormatDescriptionMatchesImageBuffer(description, buffer),
            "returned description does not match its image buffer");
    return description;
}

int main(void)
{
    vlc_samplebuffer_format_description_cache cache = { 0 };
    CVPixelBufferRef original = MakePixelBuffer(
        1920, 1080, kCVPixelFormatType_32BGRA,
        kCVImageBufferColorPrimaries_ITU_R_709_2);
    CMVideoFormatDescriptionRef first =
        CopyDescription(&cache, original, false);
    CMVideoFormatDescriptionRef reused =
        CopyDescription(&cache, original, true);
    Require(first == reused, "compatible frame returned a new description");

    CVPixelBufferRef resized = MakePixelBuffer(
        1280, 720, kCVPixelFormatType_32BGRA,
        kCVImageBufferColorPrimaries_ITU_R_709_2);
    CMVideoFormatDescriptionRef afterResize =
        CopyDescription(&cache, resized, false);
    Require(afterResize != first, "resolution change retained old description");

    CVPixelBufferRef reformatted = MakePixelBuffer(
        1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVImageBufferColorPrimaries_ITU_R_709_2);
    CMVideoFormatDescriptionRef afterPixelFormat =
        CopyDescription(&cache, reformatted, false);
    Require(afterPixelFormat != afterResize,
            "pixel-format change retained old description");

    CVPixelBufferRef recoloured = MakePixelBuffer(
        1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVImageBufferColorPrimaries_P3_D65);
    CMVideoFormatDescriptionRef afterColour =
        CopyDescription(&cache, recoloured, false);
    Require(afterColour != afterPixelFormat,
            "colour-metadata change retained old description");

    vlc_samplebuffer_format_description_cache_Clear(&cache);
    CMVideoFormatDescriptionRef afterClear =
        CopyDescription(&cache, recoloured, false);
    Require(afterClear != afterColour,
            "generation clear retained old description");

    vlc_samplebuffer_format_description_cache_Clear(&cache);
    CFRelease(first);
    CFRelease(reused);
    CFRelease(afterResize);
    CFRelease(afterPixelFormat);
    CFRelease(afterColour);
    CFRelease(afterClear);
    CVPixelBufferRelease(original);
    CVPixelBufferRelease(resized);
    CVPixelBufferRelease(reformatted);
    CVPixelBufferRelease(recoloured);
    puts("native format-description cache validation passed");
    return EXIT_SUCCESS;
}
