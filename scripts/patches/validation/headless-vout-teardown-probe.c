/* Runtime regression for a stopped/unstarted vout teardown deadlock.
 *
 * This command-line process deliberately never creates NSApplication. On
 * macOS the H.264 fixture therefore exercises VLC's renderer-start failure:
 * the decoder retains a non-NULL vout whose render thread was never cloned.
 */
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <vlc/vlc.h>

enum probe_mode
{
    PROBE_STOP,
    PROBE_NATURAL_EOF,
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
        "TIMEOUT headless vout playback or teardown did not terminate\n";
    (void) write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void sleep_milliseconds(long milliseconds)
{
    const struct timespec delay = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000,
    };
    nanosleep(&delay, NULL);
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

static int parse_mode(const char *value, enum probe_mode *mode)
{
    if (strcmp(value, "stop") == 0)
        *mode = PROBE_STOP;
    else if (strcmp(value, "natural-eof") == 0)
        *mode = PROBE_NATURAL_EOF;
    else
        return -1;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3)
    {
        fprintf(stderr, "usage: %s <seekable-h264-vod> <stop|natural-eof>\n",
                argv[0]);
        return 2;
    }

    enum probe_mode mode;
    if (parse_mode(argv[2], &mode) != 0 || install_watchdog() != 0)
        return 2;

    const char *arguments[] = {
        "--vout=dummy", "--aout=dummy", "--no-video-title-show",
    };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    if (vlc == NULL)
    {
        fprintf(stderr, "libvlc_new failed\n");
        return 2;
    }

    libvlc_media_t *media = libvlc_media_new_path(argv[1]);
    if (media == NULL)
    {
        fprintf(stderr, "libvlc_media_new_path failed\n");
        libvlc_release(vlc);
        return 2;
    }

    libvlc_media_player_t *player = libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
    {
        fprintf(stderr, "libvlc_media_player_new_from_media failed\n");
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 2;
    }

    atomic_bool saw_playing = ATOMIC_VAR_INIT(false);
    libvlc_event_manager_t *events = libvlc_media_player_event_manager(player);
    if (libvlc_event_attach(events, libvlc_MediaPlayerPlaying,
                            player_event, &saw_playing) != 0)
    {
        fprintf(stderr, "could not attach Playing observer\n");
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 2;
    }

    if (libvlc_media_player_play(player) != 0)
    {
        fprintf(stderr, "libvlc_media_player_play failed\n");
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }

    bool snapshot_ready = false;
    bool reached_terminal = false;
    libvlc_time_t media_length = -1;
    libvlc_time_t max_media_time = -1;
    for (int attempt = 0; attempt < 600; ++attempt)
    {
        const libvlc_state_t state = libvlc_media_player_get_state(player);

        swiftvlc_media_player_playback_snapshot_t snapshot = {0};
        if (swiftvlc_libvlc_media_player_get_playback_snapshot(
                player, &snapshot))
        {
            if (snapshot.media == media && snapshot.length >= 1500
             && snapshot.time >= 0 && snapshot.seekable)
            {
                media_length = snapshot.length;
                if (snapshot.time > max_media_time)
                    max_media_time = snapshot.time;
                if (mode == PROBE_STOP)
                    snapshot_ready = true;
            }
            if (snapshot.media != NULL)
                libvlc_media_release(snapshot.media);
            if (mode == PROBE_STOP && snapshot_ready)
                break;
        }

        if (mode == PROBE_NATURAL_EOF && state == libvlc_Stopped
         && media_length >= 1500 && max_media_time >= 1000)
        {
            reached_terminal = true;
            break;
        }
        sleep_milliseconds(20);
    }

    if (mode == PROBE_NATURAL_EOF
     && !atomic_load_explicit(&saw_playing, memory_order_acquire))
    {
        fprintf(stderr, "natural-EOF playback never reached Playing\n");
        libvlc_media_player_stop_async(player);
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }
    if (mode == PROBE_STOP && !snapshot_ready)
    {
        fprintf(stderr, "playback snapshot never became ready\n");
        libvlc_media_player_stop_async(player);
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }
    if (mode == PROBE_NATURAL_EOF && !reached_terminal)
    {
        fprintf(stderr,
                "natural EOF did not reach Stopped after media progression "
                "(length=%lld max_time=%lld)\n",
                (long long) media_length, (long long) max_media_time);
        libvlc_media_player_stop_async(player);
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }

    if (mode == PROBE_STOP)
        libvlc_media_player_stop_async(player);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);
    alarm(0);

    printf("PASS headless vout teardown mode=%s length=%lld max_time=%lld\n",
           argv[2], (long long) media_length, (long long) max_media_time);
    return 0;
}
