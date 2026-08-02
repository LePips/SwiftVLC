#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "VLCSampleBufferFormatDescriptionCache.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static void Fail(const char *message)
{
    fprintf(stderr, "native format-description benchmark failed: %s\n", message);
    exit(EXIT_FAILURE);
}

static long ParsePositive(const char *value, const char *name)
{
    errno = 0;
    char *end = NULL;
    long result = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || result <= 0)
    {
        fprintf(stderr, "invalid %s: %s\n", name, value);
        exit(EXIT_FAILURE);
    }
    return result;
}

static double Milliseconds(struct timeval value)
{
    return value.tv_sec * 1000.0 + value.tv_usec / 1000.0;
}

static double MonotonicMilliseconds(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value) != 0)
        Fail("clock_gettime");
    return value.tv_sec * 1000.0 + value.tv_nsec / 1000000.0;
}

int main(int argc, const char *argv[])
{
    if (argc != 7)
    {
        fprintf(stderr,
                "usage: %s baseline|cached width height fps seconds repetitions\n",
                argv[0]);
        return EXIT_FAILURE;
    }

    bool cached;
    if (strcmp(argv[1], "baseline") == 0)
        cached = false;
    else if (strcmp(argv[1], "cached") == 0)
        cached = true;
    else
        Fail("mode must be baseline or cached");

    size_t width = (size_t)ParsePositive(argv[2], "width");
    size_t height = (size_t)ParsePositive(argv[3], "height");
    long fps = ParsePositive(argv[4], "fps");
    long seconds = ParsePositive(argv[5], "seconds");
    long repetitions = ParsePositive(argv[6], "repetitions");
    unsigned long frames = (unsigned long)fps * (unsigned long)seconds;
    unsigned long iterations = frames * (unsigned long)repetitions;

    CVPixelBufferRef buffer = NULL;
    CVReturn bufferStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, NULL,
        &buffer);
    if (bufferStatus != kCVReturnSuccess || buffer == NULL)
        Fail("CVPixelBufferCreate");
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);

    vlc_samplebuffer_format_description_cache cache = { 0 };
    unsigned long creations = 0;
    unsigned long reuses = 0;
    struct rusage usageBefore;
    struct rusage usageAfter;
    if (getrusage(RUSAGE_SELF, &usageBefore) != 0)
        Fail("getrusage before");
    double wallBefore = MonotonicMilliseconds();

    for (unsigned long index = 0; index < iterations; ++index)
    {
        CMVideoFormatDescriptionRef description = NULL;
        OSStatus status;
        if (cached)
        {
            bool reused = false;
            status = vlc_samplebuffer_format_description_cache_Copy(
                &cache, buffer, &description, &reused);
            if (reused)
                ++reuses;
            else
                ++creations;
        }
        else
        {
            status = CMVideoFormatDescriptionCreateForImageBuffer(
                kCFAllocatorDefault, buffer, &description);
            ++creations;
        }
        if (status != noErr || description == NULL)
            Fail("format-description creation");
        CFRelease(description);
    }

    double wallAfter = MonotonicMilliseconds();
    if (getrusage(RUSAGE_SELF, &usageAfter) != 0)
        Fail("getrusage after");
    double cpuMilliseconds =
        Milliseconds(usageAfter.ru_utime) + Milliseconds(usageAfter.ru_stime) -
        Milliseconds(usageBefore.ru_utime) - Milliseconds(usageBefore.ru_stime);

    printf("%s,%zu,%zu,%ld,%ld,%ld,%lu,%lu,%lu,%.3f,%.3f\n",
           argv[1], width, height, fps, seconds, repetitions, iterations,
           creations, reuses, cpuMilliseconds, wallAfter - wallBefore);

    vlc_samplebuffer_format_description_cache_Clear(&cache);
    CVPixelBufferRelease(buffer);
    return EXIT_SUCCESS;
}
