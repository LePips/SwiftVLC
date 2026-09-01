#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>
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

static bool wait_for_playing(libvlc_media_player_t *player)
{
    struct timespec delay = { .tv_nsec = 20 * 1000 * 1000 };
    for (unsigned attempt = 0; attempt < 250; ++attempt)
    {
        const libvlc_state_t state = libvlc_media_player_get_state(player);
        if (state == libvlc_Playing)
            return true;
        if (state == libvlc_Error || state == libvlc_Stopped)
            return false;
        nanosleep(&delay, NULL);
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

    struct observations observations = {
        .lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = PTHREAD_COND_INITIALIZER,
    };
    const char *arguments[] = {
        "--no-audio", "--vout=dummy", "--no-video-title-show", "--quiet",
    };
    libvlc_instance_t *instance = libvlc_new(4, arguments);
    libvlc_media_player_t *player = instance != NULL
                                  ? libvlc_media_player_new(instance) : NULL;
    libvlc_event_manager_t *events = player != NULL
                                   ? libvlc_media_player_event_manager(player)
                                   : NULL;
    if (events == NULL ||
        libvlc_event_attach(events, libvlc_MediaPlayerRateChanged,
                            rate_changed, &observations) != 0)
        return 2;

    /* With no active input, the saved global control state resolves
     * synchronously and still uses the same public event bridge. */
    unsigned start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 1.25f) != 0 ||
        !wait_for_rate(&observations, start, 1.25f, 1000) ||
        fabsf(libvlc_media_player_get_rate(player) - 1.25f) >= 0.0001f)
        return 1;

    /* An idle resolution notification may repeat even though the saved value
     * is unchanged. This is why the event is not a per-request transition. */
    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 1.25f) != 0 ||
        !wait_for_rate(&observations, start, 1.25f, 1000) ||
        fabsf(libvlc_media_player_get_rate(player) - 1.25f) >= 0.0001f)
        return 1;

    libvlc_media_t *media = libvlc_media_new_path(argv[1]);
    if (media == NULL)
        return 2;
    libvlc_media_player_set_media(player, media);
    libvlc_media_release(media);
    if (libvlc_media_player_play(player) != 0 || !wait_for_playing(player))
        return 2;

    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 0.5f) != 0 ||
        !wait_for_rate(&observations, start, 0.5f, 3000) ||
        fabsf(libvlc_media_player_get_rate(player) - 0.5f) >= 0.0001f)
        return 1;

    /* A successfully queued active-input callback describes a resolved state
     * transition: setting the already-effective value is silent. */
    const unsigned same_rate_start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 0.5f) != 0)
        return 1;
    struct timespec settle = { .tv_nsec = 250 * 1000 * 1000 };
    nanosleep(&settle, NULL);
    if (observation_count(&observations) != same_rate_start)
        return 1;

    start = observation_count(&observations);
    if (libvlc_media_player_set_rate(player, 2.f) != 0 ||
        !wait_for_rate(&observations, start, 2.f, 3000) ||
        observation_count(&observations) != same_rate_start + 1 ||
        fabsf(libvlc_media_player_get_rate(player) - 2.f) >= 0.0001f)
        return 1;

    libvlc_event_detach(events, libvlc_MediaPlayerRateChanged,
                        rate_changed, &observations);
    libvlc_media_player_stop_async(player);
    libvlc_media_player_release(player);
    libvlc_release(instance);
    pthread_cond_destroy(&observations.changed);
    pthread_mutex_destroy(&observations.lock);
    return 0;
}
