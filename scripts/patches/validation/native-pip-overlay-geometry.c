#include "VLCSampleBufferOverlayGeometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static void Fail(const char *message)
{
    fprintf(stderr, "native PiP overlay geometry failed: %s\n", message);
    exit(EXIT_FAILURE);
}

static void ExpectNear(CGFloat actual, CGFloat expected, const char *message)
{
    if (fabs(actual - expected) > 0.001)
        Fail(message);
}

static void ExpectFrame(CGRect actual, CGRect expected, const char *message)
{
    ExpectNear(actual.origin.x, expected.origin.x, message);
    ExpectNear(actual.origin.y, expected.origin.y, message);
    ExpectNear(actual.size.width, expected.size.width, message);
    ExpectNear(actual.size.height, expected.size.height, message);
}

int main(void)
{
    CGRect mapped;
    bool visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(100, 50, 200, 100), CGRectMake(0, 0, 1920, 1080),
        1080, 1920, 1080, &mapped);
    if (!visible)
        Fail("full-frame region was rejected");
    ExpectFrame(mapped, CGRectMake(100, 50, 200, 100),
                "identity mapping changed geometry");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(960, 60, 960, 540), CGRectMake(0, 60, 1920, 1080),
        1200, 1920, 1080, &mapped);
    if (!visible)
        Fail("letterboxed region was rejected");
    ExpectFrame(mapped, CGRectMake(960, 0, 960, 540),
                "letterbox offset was not removed");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(960, 60, 960, 540), CGRectMake(0, 60, 1920, 1080),
        1200, 3840, 2160, &mapped);
    if (!visible)
        Fail("adaptive-resolution region was rejected");
    ExpectFrame(mapped, CGRectMake(1920, 0, 1920, 1080),
                "adaptive-resolution scaling was incorrect");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(-20, 100, 40, 40), CGRectMake(0, 0, 1920, 1080),
        1080, 1920, 1080, &mapped);
    if (!visible)
        Fail("partially visible region was rejected");
    ExpectFrame(mapped, CGRectMake(-20, 100, 40, 40),
                "partially visible region was unexpectedly clipped");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(2000, 100, 40, 40), CGRectMake(0, 0, 1920, 1080),
        1080, 1920, 1080, &mapped);
    if (visible)
        Fail("offscreen region was accepted");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(0, 0, 10, 10), CGRectZero, 1080, 1920, 1080,
        &mapped);
    if (visible)
        Fail("empty video placement was accepted");

    visible = vlc_samplebuffer_map_overlay_region(
        CGRectMake(NAN, 0, 10, 10), CGRectMake(0, 0, 1920, 1080),
        1080, 1920, 1080, &mapped);
    if (visible)
        Fail("non-finite region was accepted");

    puts("native PiP overlay geometry validation passed");
    return EXIT_SUCCESS;
}
