#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <vlc/vlc.h>

#ifndef SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION
# define SWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION 7
#endif

enum { maximum_rates = 32 };

struct observations
{
    pthread_mutex_t lock;
    pthread_cond_t changed;
    unsigned count;
    float rates[maximum_rates];
    bool playing;
    bool terminal;
    int last_lifecycle_event;
};

static void rate_changed(const libvlc_event_t *event, void *opaque)
{
    struct observations *observations = opaque;
    if (event->type != libvlc_MediaPlayerRateChanged)
        return;

    pthread_mutex_lock(&observations->lock);
    if (observations->count < maximum_rates)
        observations->rates[observations->count] =
            event->u.media_player_rate_changed.new_rate;
    observations->count++;
    pthread_cond_broadcast(&observations->changed);
    pthread_mutex_unlock(&observations->lock);
}

static void lifecycle_changed(const libvlc_event_t *event, void *opaque)
{
    struct observations *observations = opaque;
    pthread_mutex_lock(&observations->lock);
    observations->last_lifecycle_event = event->type;
    if (event->type == libvlc_MediaPlayerPlaying)
        observations->playing = true;
    else if (event->type == libvlc_MediaPlayerStopped ||
             event->type == libvlc_MediaPlayerEncounteredError)
        observations->terminal = true;
    pthread_cond_broadcast(&observations->changed);
    pthread_mutex_unlock(&observations->lock);
}

static void watchdog_expired(int signal_number)
{
    (void) signal_number;
    static const char message[] =
        "TIMEOUT effective-rate playback or teardown did not terminate\n";
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

static struct timespec deadline_after_ms(long milliseconds)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += milliseconds / 1000;
    deadline.tv_nsec += (milliseconds % 1000) * 1000000;
    if (deadline.tv_nsec >= 1000000000)
    {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000;
    }
    return deadline;
}

static bool wait_for_rate(struct observations *observations,
                          unsigned start, float expected, long timeout_ms)
{
    struct timespec deadline = deadline_after_ms(timeout_ms);
    pthread_mutex_lock(&observations->lock);
    for (;;)
    {
        const unsigned available = observations->count < maximum_rates
                                 ? observations->count : maximum_rates;
        for (unsigned index = start; index < available; ++index)
        {
            if (fabsf(observations->rates[index] - expected) < 0.0001f)
            {
                pthread_mutex_unlock(&observations->lock);
                return true;
            }
        }
        if (pthread_cond_timedwait(&observations->changed, &observations->lock,
                                   &deadline) != 0)
        {
            pthread_mutex_unlock(&observations->lock);
            return false;
        }
    }
}

static unsigned observation_count(struct observations *observations)
{
    pthread_mutex_lock(&observations->lock);
    unsigned count = observations->count;
    pthread_mutex_unlock(&observations->lock);
    return count;
}

static bool wait_for_playing(struct observations *observations,
                             long timeout_ms)
{
    struct timespec deadline = deadline_after_ms(timeout_ms);
    pthread_mutex_lock(&observations->lock);
    while (!observations->playing && !observations->terminal)
    {
        int result = pthread_cond_timedwait(&observations->changed,
                                            &observations->lock, &deadline);
        if (result == ETIMEDOUT)
            break;
        if (result != 0)
        {
            observations->terminal = true;
            break;
        }
    }
    bool playing = observations->playing;
    pthread_mutex_unlock(&observations->lock);
    return playing;
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

    struct observations observations = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
        .last_lifecycle_event = -1,
    };
    static const libvlc_event_type_t lifecycle_events[] = {
        libvlc_MediaPlayerOpening,
        libvlc_MediaPlayerPlaying,
        libvlc_MediaPlayerStopped,
        libvlc_MediaPlayerEncounteredError,
    };
    const char *arguments[] = {
        "--no-audio", "--vout=dummy", "--no-video-title-show", "--quiet",
    };
    libvlc_instance_t *instance = NULL;
    libvlc_media_player_t *player = NULL;
    libvlc_media_t *media = NULL;
    libvlc_event_manager_t *events = NULL;
    bool rate_attached = false;
    bool play_requested = false;
    unsigned lifecycle_attached = 0;
    int exit_status = 2;
    const char *failure_stage = "libvlc setup";

    instance = libvlc_new(4, arguments);
    player = instance != NULL ? libvlc_media_player_new(instance) : NULL;
    events = player != NULL ? libvlc_media_player_event_manager(player) : NULL;
    if (events == NULL)
        goto cleanup;
    if (libvlc_event_attach(events, libvlc_MediaPlayerRateChanged,
                            rate_changed, &observations) != 0)
    {
        failure_stage = "rate-event attachment";
        goto cleanup;
    }
    rate_attached = true;
    for (unsigned index = 0;
         index < sizeof(lifecycle_events) / sizeof(lifecycle_events[0]);
         ++index)
    {
        if (libvlc_event_attach(events, lifecycle_events[index],
                                lifecycle_changed, &observations) != 0)
        {
            failure_stage = "lifecycle-event attachment";
            goto cleanup;
        }
        lifecycle_attached++;
    }

    /* With no active input, the saved global control state resolves
     * synchronously and still uses the same public event bridge. */
    failure_stage = "first idle 1.25x resolution";
    unsigned start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 1.25f) != 0 ||
        !wait_for_rate(&observations, start, 1.25f, 1000) ||
        fabsf(libvlc_media_player_get_rate(player) - 1.25f) >= 0.0001f)
    {
        exit_status = 1;
        goto cleanup;
    }

    /* An idle resolution notification may repeat even though the saved value
     * is unchanged. This is why the event is not a per-request transition. */
    failure_stage = "repeated idle 1.25x resolution";
    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 1.25f) != 0 ||
        !wait_for_rate(&observations, start, 1.25f, 1000) ||
        fabsf(libvlc_media_player_get_rate(player) - 1.25f) >= 0.0001f)
    {
        exit_status = 1;
        goto cleanup;
    }

    failure_stage = "media creation";
    media = libvlc_media_new_path(argv[1]);
    if (media == NULL)
        goto cleanup;
    libvlc_media_player_set_media(player, media);
    libvlc_media_release(media);
    media = NULL;
    failure_stage = "Playing lifecycle event";
    if (libvlc_media_player_play(player) != 0)
        goto cleanup;
    play_requested = true;
    if (!wait_for_playing(&observations, 5000))
    {
        exit_status = 1;
        goto cleanup;
    }

    failure_stage = "active 0.5x resolution";
    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 0.5f) != 0 ||
        !wait_for_rate(&observations, start, 0.5f, 3000) ||
        fabsf(libvlc_media_player_get_rate(player) - 0.5f) >= 0.0001f)
    {
        exit_status = 1;
        goto cleanup;
    }

    /* A successfully queued active-input callback describes a resolved state
     * transition: setting the already-effective value is silent. */
    failure_stage = "active same-rate silence";
    const unsigned same_rate_start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 0.5f) != 0)
    {
        exit_status = 1;
        goto cleanup;
    }
    struct timespec settle = { .tv_nsec = 250 * 1000 * 1000 };
    nanosleep(&settle, NULL);
    if (observation_count(&observations) != same_rate_start)
    {
        exit_status = 1;
        goto cleanup;
    }

    failure_stage = "active 2.0x resolution";
    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 2.f) != 0 ||
        !wait_for_rate(&observations, start, 2.f, 3000) ||
        observation_count(&observations) != same_rate_start + 1 ||
        fabsf(libvlc_media_player_get_rate(player) - 2.f) >= 0.0001f)
    {
        exit_status = 1;
        goto cleanup;
    }
    exit_status = 0;

cleanup:
    if (exit_status != 0)
    {
        const libvlc_state_t state = player != NULL
                                   ? libvlc_media_player_get_state(player)
                                   : libvlc_NothingSpecial;
        pthread_mutex_lock(&observations.lock);
        const int last_event = observations.last_lifecycle_event;
        const unsigned rate_count = observations.count;
        pthread_mutex_unlock(&observations.lock);
        const char *message = libvlc_errmsg();
        fprintf(stderr,
                "effective-rate probe failed at %s: state=%d "
                "last_event=%d rate_events=%u libvlc_error=%s\n",
                failure_stage, (int) state, last_event, rate_count,
                message != NULL ? message : "none");
    }
    if (events != NULL)
    {
        for (unsigned index = 0; index < lifecycle_attached; ++index)
            libvlc_event_detach(events, lifecycle_events[index],
                                lifecycle_changed, &observations);
        if (rate_attached)
            libvlc_event_detach(events, libvlc_MediaPlayerRateChanged,
                                rate_changed, &observations);
    }
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
    const unsigned final_rate_count = observation_count(&observations);
    pthread_cond_destroy(&observations.changed);
    pthread_mutex_destroy(&observations.lock);
    alarm(0);
    if (exit_status == 0)
        printf("PASS effective-rate idle/active lifecycle events=%u\n",
               final_rate_count);
    return exit_status;
}
