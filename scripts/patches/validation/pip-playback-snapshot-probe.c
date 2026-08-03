/* Runtime proof for patch 0022 (identity-coherent native PiP playback state). */
#include <stdio.h>
#include <time.h>
#include <vlc/vlc.h>

static void sleep_milliseconds(long milliseconds)
{
    struct timespec delay = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000000,
    };
    nanosleep(&delay, NULL);
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <seekable-vod>\n", argv[0]);
        return 2;
    }

    const char *arguments[] = { "--no-audio", "--vout=dummy", "--aout=dummy" };
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

    if (swiftvlc_libvlc_pip_extensions_version() < 2)
    {
        fprintf(stderr, "playback snapshot extension version is below 2\n");
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }

    if (libvlc_media_player_play(player) != 0)
    {
        fprintf(stderr, "libvlc_media_player_play failed\n");
        libvlc_media_player_release(player);
        libvlc_media_release(media);
        libvlc_release(vlc);
        return 1;
    }

    swiftvlc_media_player_media_length_snapshot_t snapshot = {0};
    int ready = 0;
    for (int attempt = 0; attempt < 100; ++attempt)
    {
        if (swiftvlc_libvlc_media_player_get_media_length_snapshot(player, &snapshot))
        {
            ready = snapshot.media == media && snapshot.length >= 1500
                && snapshot.time >= 0 && snapshot.seekable;
            libvlc_media_release(snapshot.media);
            snapshot.media = NULL;
            if (ready)
                break;
        }
        sleep_milliseconds(50);
    }

    libvlc_media_player_stop_async(player);
    libvlc_media_player_release(player);
    libvlc_media_release(media);
    libvlc_release(vlc);

    if (!ready)
    {
        fprintf(stderr, "snapshot never reported coherent seekable VOD state\n");
        return 1;
    }

    printf("PASS length=%lld time=%lld seekable=true\n",
           (long long)snapshot.length, (long long)snapshot.time);
    return 0;
}
