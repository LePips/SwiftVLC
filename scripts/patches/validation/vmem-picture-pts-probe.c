/* Public runtime/ABI proof for SwiftVLC's version-6 vmem picture PTS. */
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <vlc/vlc.h>

#ifndef SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION
# define SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION 6
#endif

_Static_assert(SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US == INT64_MIN,
               "invalid vmem picture PTS sentinel changed");
#if defined(__clang__) || defined(__GNUC__)
_Static_assert(!__builtin_types_compatible_p(
                   swiftvlc_video_display_status_cb,
                   swiftvlc_video_display_status_v2_cb),
               "v6 must not mutate the version-4 callback typedef");
#endif

enum { maximum_samples = 256 };

struct vmem_context
{
    pthread_mutex_t lock;
    void *pixels;
    size_t pixel_size;
    unsigned callback_count;
    unsigned invalid_count;
    int64_t pts[maximum_samples];
};

static void *vmem_lock(void *opaque, void **planes)
{
    struct vmem_context *context = opaque;
    planes[0] = context->pixels;
    return context;
}

static int vmem_display_v4(void *opaque, void *picture)
{
    return opaque == picture ? 0 : -EINVAL;
}

static int vmem_display_v6(void *opaque, void *picture,
                           int64_t picture_pts_us)
{
    struct vmem_context *context = opaque;
    if (picture != context)
        return -EINVAL;
    pthread_mutex_lock(&context->lock);
    if (context->callback_count < maximum_samples)
        context->pts[context->callback_count] = picture_pts_us;
    context->callback_count++;
    if (picture_pts_us == SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US)
        context->invalid_count++;
    pthread_mutex_unlock(&context->lock);
    return 0;
}

static unsigned vmem_setup(
    void **opaque, char *chroma,
    const swiftvlc_video_format_geometry_t *geometry,
    unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines)
{
    struct vmem_context *context = *opaque;
    if (geometry == NULL || geometry->visible_width == 0 ||
        geometry->visible_height == 0)
        return 0;

    memcpy(chroma, "RV32", 4);
    *width = geometry->visible_width;
    *height = geometry->visible_height;
    pitches[0] = ((*width * 4u) + 63u) & ~63u;
    lines[0] = *height;
    size_t size = (size_t)pitches[0] * lines[0];
    void *pixels = NULL;
    if (posix_memalign(&pixels, 64, size) != 0)
        return 0;
    free(context->pixels);
    context->pixels = pixels;
    context->pixel_size = size;
    memset(context->pixels, 0, context->pixel_size);
    return 1;
}

static void vmem_cleanup(void *opaque)
{
    struct vmem_context *context = opaque;
    free(context->pixels);
    context->pixels = NULL;
    context->pixel_size = 0;
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec duration = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000,
    };
    nanosleep(&duration, NULL);
}

static bool wait_for_samples(libvlc_media_player_t *player,
                             struct vmem_context *context)
{
    for (unsigned iteration = 0; iteration < 200; ++iteration)
    {
        pthread_mutex_lock(&context->lock);
        unsigned count = context->callback_count;
        pthread_mutex_unlock(&context->lock);
        if (count >= 3)
            return true;
        libvlc_state_t state = libvlc_media_player_get_state(player);
        if (state == libvlc_Stopped || state == libvlc_Error)
            return count >= 3;
        sleep_milliseconds(50);
    }
    return false;
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <video-fixture>\n", argv[0]);
        return 2;
    }
    if (swiftvlc_libvlc_pip_extensions_version() !=
        SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION)
    {
        fprintf(stderr, "unexpected SwiftVLC extension version: %u\n",
                swiftvlc_libvlc_pip_extensions_version());
        return 1;
    }

    /* These assignments are a compile-time guard that v4 and v6 remain two
     * additive, independently callable ABIs. */
    swiftvlc_video_display_status_cb status_v4 = vmem_display_v4;
    swiftvlc_video_display_status_v2_cb status_v6 = vmem_display_v6;
    (void)status_v4;

    const char *arguments[] = {
        "--no-audio", "--no-video-title-show", "--quiet",
    };
    libvlc_instance_t *instance = libvlc_new(
        (int)(sizeof(arguments) / sizeof(arguments[0])), arguments);
    if (instance == NULL)
        return 2;
    libvlc_media_player_t *player = libvlc_media_player_new(instance);
    libvlc_media_t *media = libvlc_media_new_path(argv[1]);
    if (player == NULL || media == NULL)
        return 2;

    struct vmem_context context = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
    };
    int result = swiftvlc_libvlc_video_set_callbacks_atomic_v2(
        player, vmem_lock, NULL, NULL, status_v6, vmem_setup,
        vmem_cleanup, &context);
    if (result != 0)
    {
        fprintf(stderr, "valid atomic-v2 install failed: %d\n", result);
        return 1;
    }

    /* A rejected partial tuple must not replace the complete generation that
     * the subsequent vmem Open acquires. */
    result = swiftvlc_libvlc_video_set_callbacks_atomic_v2(
        player, vmem_lock, NULL, NULL, status_v6, NULL,
        vmem_cleanup, &context);
    if (result != -EINVAL)
    {
        fprintf(stderr, "partial atomic-v2 tuple returned %d\n", result);
        return 1;
    }

    libvlc_media_player_set_media(player, media);
    libvlc_media_release(media);
    if (libvlc_media_player_play(player) != 0 ||
        !wait_for_samples(player, &context))
    {
        fprintf(stderr, "timed out waiting for timestamp-bearing frames\n");
        return 1;
    }
    libvlc_media_player_stop_async(player);
    for (unsigned iteration = 0; iteration < 200; ++iteration)
    {
        libvlc_state_t state = libvlc_media_player_get_state(player);
        if (state == libvlc_Stopped || state == libvlc_Error)
            break;
        sleep_milliseconds(10);
    }

    pthread_mutex_lock(&context.lock);
    unsigned count = context.callback_count;
    unsigned retained = count < maximum_samples ? count : maximum_samples;
    unsigned invalid = context.invalid_count;
    bool monotonic = true;
    bool distinct = false;
    for (unsigned index = 0; index < retained; ++index)
    {
        if (context.pts[index] == SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US)
            continue;
        if (index > 0 && context.pts[index] < context.pts[index - 1])
            monotonic = false;
        if (index > 0 && context.pts[index] != context.pts[index - 1])
            distinct = true;
    }
    pthread_mutex_unlock(&context.lock);

    libvlc_media_player_release(player);
    libvlc_release(instance);
    pthread_mutex_destroy(&context.lock);

    if (count < 3 || invalid != 0 || !monotonic || !distinct)
    {
        fprintf(stderr,
                "bad vmem output-attempt PTS evidence: count=%u invalid=%u "
                "monotonic=%d distinct=%d\n",
                count, invalid, monotonic, distinct);
        return 1;
    }
    printf("PASS v6 vmem output-attempt PTS count=%u first=%lld last=%lld\n",
           count, (long long)context.pts[0],
           (long long)context.pts[retained - 1]);
    return 0;
}
