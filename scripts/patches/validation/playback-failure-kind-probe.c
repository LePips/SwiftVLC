/* Runtime proof for patch 0020 (playback subsystem failure attribution).
 *
 * The engine compiles even if a failure site is accidentally left mapped to
 * generic, so compile coverage alone is insufficient. This probe verifies the
 * public EncounteredError payload for an unavailable access module, malformed
 * local media, and a recognized container whose codec fourcc was replaced by
 * an unsupported value.
 *
 * Prepare the two local fixtures and run against a patched native build:
 *
 *   printf 'not media' > /tmp/swiftvlc-malformed.mp4
 *   cp Tests/SwiftVLCTests/Fixtures/test.mp4 /tmp/swiftvlc-unknown-codec.mp4
 *   perl -pi -e 's/avc1/zzzz/g' /tmp/swiftvlc-unknown-codec.mp4
 *   V=scripts/.build-libvlc/vlc
 *   cp "$V/build-macosx-arm64/static-lib/libvlc-full-static.a" \
 *     /tmp/libvlc-full-static-probe.a
 *   ./scripts/fix-duplicate-symbols.sh /tmp/libvlc-full-static-probe.a
 *   clang -o /tmp/playback-failure-kind-probe \
 *     scripts/patches/validation/playback-failure-kind-probe.c \
 *     -I Sources/CLibVLC/include /tmp/libvlc-full-static-probe.a \
 *     -framework AppKit -framework AudioToolbox -framework AudioUnit \
 *     -framework AVFoundation -framework AVKit -framework CoreAudio \
 *     -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
 *     -framework CoreMedia -framework CoreServices -framework CoreText \
 *     -framework CoreVideo -framework Foundation -framework IOKit \
 *     -framework IOSurface -framework OpenGL -framework QuartzCore \
 *     -framework Security -framework SystemConfiguration -framework VideoToolbox \
 *     -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz
 *   /tmp/playback-failure-kind-probe \
 *     /tmp/swiftvlc-malformed.mp4 /tmp/swiftvlc-unknown-codec.mp4
 */
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <vlc/vlc.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int seen;
static libvlc_playback_failure_kind_t last_failure;

static const char *failure_name(libvlc_playback_failure_kind_t failure)
{
    switch (failure) {
    case libvlc_playback_failure_unknown: return "unknown";
    case libvlc_playback_failure_source: return "source";
    case libvlc_playback_failure_demux: return "demux";
    case libvlc_playback_failure_decoder: return "decoder";
    case libvlc_playback_failure_renderer: return "renderer";
    case libvlc_playback_failure_output: return "output";
    }
    return "invalid";
}

static void on_event(const libvlc_event_t *event, void *data)
{
    (void)data;
    if (event->type != libvlc_MediaPlayerEncounteredError)
        return;

    pthread_mutex_lock(&lock);
    last_failure = event->u.media_player_encountered_error.failure;
    seen = 1;
    pthread_cond_signal(&condition);
    pthread_mutex_unlock(&lock);
}

static int run(libvlc_instance_t *vlc, const char *mrl, int is_location,
               libvlc_playback_failure_kind_t expected)
{
    libvlc_media_t *media = is_location ? libvlc_media_new_location(mrl)
                                        : libvlc_media_new_path(mrl);
    if (media == NULL)
    {
        fprintf(stderr, "cannot create media for %s\n", mrl);
        return 1;
    }

    libvlc_media_player_t *player = libvlc_media_player_new_from_media(vlc, media);
    if (player == NULL)
    {
        fprintf(stderr, "cannot create player for %s\n", mrl);
        libvlc_media_release(media);
        return 1;
    }

    libvlc_event_manager_t *events = libvlc_media_player_event_manager(player);
    libvlc_event_attach(events, libvlc_MediaPlayerEncounteredError, on_event, NULL);

    pthread_mutex_lock(&lock);
    seen = 0;
    last_failure = libvlc_playback_failure_unknown;
    pthread_mutex_unlock(&lock);

    libvlc_media_player_play(player);

    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 15;
    pthread_mutex_lock(&lock);
    while (!seen && pthread_cond_timedwait(&condition, &lock, &deadline) == 0) {}
    int got_event = seen;
    libvlc_playback_failure_kind_t actual = last_failure;
    pthread_mutex_unlock(&lock);

    libvlc_media_player_stop_async(player);
    libvlc_media_player_release(player);
    libvlc_media_release(media);

    int passed = got_event && actual == expected;
    printf("%s expected=%-8s actual=%s\n", passed ? "PASS" : "FAIL",
           failure_name(expected), got_event ? failure_name(actual) : "no event");
    return passed ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc != 3)
    {
        fprintf(stderr, "usage: %s <malformed-media> <unsupported-codec-media>\n", argv[0]);
        return 2;
    }

    const char *arguments[] = { "--no-audio", "--vout=dummy", "--aout=dummy" };
    libvlc_instance_t *vlc = libvlc_new(3, arguments);
    if (vlc == NULL)
    {
        fprintf(stderr, "libvlc_new failed\n");
        return 2;
    }

    int result = 0;
    result |= run(vlc, "swiftvlc-missing-source://unavailable", 1,
                  libvlc_playback_failure_source);
    result |= run(vlc, argv[1], 0, libvlc_playback_failure_demux);
    result |= run(vlc, argv[2], 0, libvlc_playback_failure_decoder);

    libvlc_release(vlc);
    printf(result ? "RESULT: FAILED\n" : "RESULT: PASSED\n");
    return result;
}
