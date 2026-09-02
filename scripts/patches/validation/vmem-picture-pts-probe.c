/* Public runtime/ABI proof for SwiftVLC's version-6 vmem picture PTS. */
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
    bool has_valid_pts;
    bool has_distinct_pts;
    bool monotonic_pts;
    int64_t first_valid_pts;
    int64_t last_valid_pts;
    int64_t pts[maximum_samples];
};

static void player_event(const libvlc_event_t *event, void *opaque)
{
    if (event->type == libvlc_MediaPlayerPlaying)
        atomic_store_explicit((atomic_bool *) opaque, true,
                              memory_order_release);
}

static void watchdog_expired(int signal_number)
{
    (void) signal_number;
    static const char message[] =
        "TIMEOUT vmem PTS playback or teardown did not terminate\n";
    (void) write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static int install_watchdog(void)
{
    struct sigaction action = {0};
    action.sa_handler = watchdog_expired;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) != 0)
    {
        perror("sigaction");
        return -1;
    }
    alarm(20);
    return 0;
}

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
    else if (!context->has_valid_pts)
    {
        context->has_valid_pts = true;
        context->first_valid_pts = picture_pts_us;
        context->last_valid_pts = picture_pts_us;
    }
    else
    {
        if (picture_pts_us != context->first_valid_pts)
            context->has_distinct_pts = true;
        if (picture_pts_us < context->last_valid_pts)
            context->monotonic_pts = false;
        context->last_valid_pts = picture_pts_us;
    }
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
                             struct vmem_context *context,
                             atomic_bool *saw_playing)
{
    bool saw_started = false;
    for (unsigned iteration = 0; iteration < 200; ++iteration)
    {
        pthread_mutex_lock(&context->lock);
        unsigned count = context->callback_count;
        bool distinct = context->has_distinct_pts;
        pthread_mutex_unlock(&context->lock);
        if (count >= 3 && distinct)
            return true;
        libvlc_state_t state = libvlc_media_player_get_state(player);
        if (count > 0 ||
            atomic_load_explicit(saw_playing, memory_order_acquire) ||
            state == libvlc_Opening || state == libvlc_Buffering ||
            state == libvlc_Playing || state == libvlc_Paused ||
            state == libvlc_Stopping)
            saw_started = true;
        if (state == libvlc_Error)
            return false;
        if (state == libvlc_Stopped && saw_started)
            return false;
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
    if (install_watchdog() != 0)
        return 2;

    /* These assignments are a compile-time guard that v4 and v6 remain two
     * additive, independently callable ABIs. */
    swiftvlc_video_display_status_cb status_v4 = vmem_display_v4;
    swiftvlc_video_display_status_v2_cb status_v6 = vmem_display_v6;
    (void)status_v4;

    const char *arguments[] = {
        "--no-audio", "--no-video-title-show", "--quiet",
    };
    struct vmem_context context = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .monotonic_pts = true,
    };
    atomic_bool saw_playing = ATOMIC_VAR_INIT(false);
    libvlc_instance_t *instance = NULL;
    libvlc_media_player_t *player = NULL;
    libvlc_media_t *media = NULL;
    libvlc_event_manager_t *events = NULL;
    bool playing_attached = false;
    bool play_requested = false;
    int exit_status = 2;
    const char *failure_stage = "libvlc setup";
    unsigned count = 0;
    unsigned invalid = 0;
    bool monotonic = false;
    bool distinct = false;
    int64_t first_pts = SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US;
    int64_t last_pts = SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US;

    instance = libvlc_new(
        (int)(sizeof(arguments) / sizeof(arguments[0])), arguments);
    player = instance != NULL ? libvlc_media_player_new(instance) : NULL;
    media = libvlc_media_new_path(argv[1]);
    events = player != NULL ? libvlc_media_player_event_manager(player) : NULL;
    if (events == NULL || media == NULL)
        goto cleanup;
    if (libvlc_event_attach(events, libvlc_MediaPlayerPlaying,
                            player_event, &saw_playing) != 0)
    {
        failure_stage = "Playing-event attachment";
        goto cleanup;
    }
    playing_attached = true;

    failure_stage = "complete atomic-v2 generation";
    int result = swiftvlc_libvlc_video_set_callbacks_atomic_v2(
        player, vmem_lock, NULL, NULL, status_v6, vmem_setup,
        vmem_cleanup, &context);
    if (result != 0)
    {
        fprintf(stderr, "valid atomic-v2 install failed: %d\n", result);
        exit_status = 1;
        goto cleanup;
    }

    /* A rejected partial tuple must not replace the complete generation that
     * the subsequent vmem Open acquires. */
    failure_stage = "partial atomic-v2 rejection";
    result = swiftvlc_libvlc_video_set_callbacks_atomic_v2(
        player, vmem_lock, NULL, NULL, status_v6, NULL,
        vmem_cleanup, &context);
    if (result != -EINVAL)
    {
        fprintf(stderr, "partial atomic-v2 tuple returned %d\n", result);
        exit_status = 1;
        goto cleanup;
    }

    libvlc_media_player_set_media(player, media);
    libvlc_media_release(media);
    media = NULL;
    failure_stage = "timestamp-bearing frame evidence";
    if (libvlc_media_player_play(player) != 0)
        goto cleanup;
    play_requested = true;
    if (!wait_for_samples(player, &context, &saw_playing))
    {
        exit_status = 1;
        goto cleanup;
    }
    libvlc_media_player_stop_async(player);
    bool stop_completed = false;
    for (unsigned iteration = 0; iteration < 200; ++iteration)
    {
        libvlc_state_t state = libvlc_media_player_get_state(player);
        if (state == libvlc_Stopped)
        {
            stop_completed = true;
            break;
        }
        if (state == libvlc_Error)
            break;
        sleep_milliseconds(10);
    }
    if (!stop_completed)
    {
        failure_stage = "bounded stop completion";
        exit_status = 1;
        goto cleanup;
    }

    /* Stop is asynchronous, and a stopped player can still own teardown
     * work. Release joins that work before the final evidence snapshot so no
     * later callback can invalidate a PASS or escape its reported count. */
    play_requested = false;
    if (events != NULL && playing_attached)
    {
        libvlc_event_detach(events, libvlc_MediaPlayerPlaying,
                            player_event, &saw_playing);
        playing_attached = false;
    }
    libvlc_media_player_release(player);
    player = NULL;
    events = NULL;

    pthread_mutex_lock(&context.lock);
    count = context.callback_count;
    invalid = context.invalid_count;
    monotonic = context.monotonic_pts;
    distinct = context.has_distinct_pts;
    first_pts = context.first_valid_pts;
    last_pts = context.last_valid_pts;
    pthread_mutex_unlock(&context.lock);

    if (count < 3 || invalid != 0 || !monotonic || !distinct)
    {
        fprintf(stderr,
                "bad vmem output-attempt PTS evidence: count=%u invalid=%u "
                "monotonic=%d distinct=%d\n",
                count, invalid, monotonic, distinct);
        failure_stage = "final PTS quality assertions";
        exit_status = 1;
        goto cleanup;
    }
    exit_status = 0;

cleanup:
    if (exit_status != 0)
    {
        pthread_mutex_lock(&context.lock);
        const unsigned observed_count = context.callback_count;
        const bool observed_distinct = context.has_distinct_pts;
        pthread_mutex_unlock(&context.lock);
        const libvlc_state_t state = player != NULL
                                   ? libvlc_media_player_get_state(player)
                                   : libvlc_NothingSpecial;
        const char *message = libvlc_errmsg();
        fprintf(stderr,
                "vmem PTS probe failed at %s: state=%d saw_playing=%d "
                "callbacks=%u distinct=%d libvlc_error=%s\n",
                failure_stage, (int) state,
                atomic_load_explicit(&saw_playing, memory_order_acquire),
                observed_count, observed_distinct,
                message != NULL ? message : "none");
    }
    if (events != NULL && playing_attached)
        libvlc_event_detach(events, libvlc_MediaPlayerPlaying,
                            player_event, &saw_playing);
    if (media != NULL)
        libvlc_media_release(media);
    if (player != NULL)
    {
        if (play_requested)
            libvlc_media_player_stop_async(player);
        libvlc_media_player_release(player);
    }
    if (instance != NULL)
        libvlc_release(instance);
    pthread_mutex_destroy(&context.lock);
    alarm(0);
    if (exit_status == 0)
        printf("PASS v6 vmem output-attempt PTS count=%u first=%lld last=%lld\n",
               count, (long long) first_pts, (long long) last_pts);
    return exit_status;
}
