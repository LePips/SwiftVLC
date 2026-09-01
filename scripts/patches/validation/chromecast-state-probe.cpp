/****************************************************************************
 * Native model probe for SwiftVLC patch 0034's exact Cast helpers.
 ****************************************************************************/

#include "chromecast_demux_eof.hpp"
#include "chromecast_protocol.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>

static int failures = 0;

#define CHECK(condition)                                                        \
    do                                                                          \
    {                                                                           \
        if (!(condition))                                                       \
        {                                                                       \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,      \
                         #condition);                                            \
            ++failures;                                                         \
        }                                                                       \
    } while (0)

static void check_request_attribution()
{
    chromecast_media_request_tracker requests;
    const vlc_tick_t deadline = VLC_TICK_FROM_SEC(10);
    CHECK(requests.record(chromecast_media_command::Load, 11, deadline));
    CHECK(requests.record(chromecast_media_command::Play, 12, deadline));
    CHECK(requests.record(chromecast_media_command::Pause, 13, deadline));
    CHECK(requests.record(chromecast_media_command::Stop, 14, deadline));
    CHECK(requests.record(chromecast_media_command::Status, 15, deadline));
    CHECK(requests.next_deadline() == deadline);

    CHECK(!requests.record(chromecast_media_command::Load, 99, deadline));
    CHECK(requests.match(11) == chromecast_media_command::Load);
    CHECK(requests.acknowledge(13) == chromecast_media_command::Pause);
    CHECK(!requests.pending(chromecast_media_command::Pause));
    CHECK(requests.match(11) == chromecast_media_command::Load);
    CHECK(requests.match(12) == chromecast_media_command::Play);
    CHECK(requests.match(14) == chromecast_media_command::Stop);
    CHECK(requests.match(15) == chromecast_media_command::Status);
    CHECK(requests.acknowledge(777) == chromecast_media_command::None);
    CHECK(!requests.record(chromecast_media_command::None, 16, deadline));
    CHECK(!requests.record(chromecast_media_command::Pause, 0, deadline));
    CHECK(!requests.record(chromecast_media_command::Pause, 16,
                           VLC_TICK_INVALID));
    CHECK(!requests.expired(chromecast_media_command::Load, deadline - 1));
    CHECK(requests.expired(chromecast_media_command::Load, deadline));

    requests.clear();
    CHECK(requests.next_deadline() == VLC_TICK_INVALID);
    CHECK(requests.record(chromecast_media_command::Load, 21, deadline));
    CHECK(!requests.record(chromecast_media_command::Pause, 21, deadline));
    CHECK(!requests.pending(chromecast_media_command::Pause));
    requests.clear();
    CHECK(!requests.pending(chromecast_media_command::Load));

    CHECK(requests.record(chromecast_media_command::Load, 31,
                          VLC_TICK_FROM_SEC(50)));
    CHECK(requests.record(chromecast_media_command::Pause, 32,
                          VLC_TICK_FROM_SEC(20)));
    CHECK(requests.record(chromecast_media_command::Status, 33,
                          VLC_TICK_FROM_SEC(30)));
    CHECK(requests.next_deadline() == VLC_TICK_FROM_SEC(20));
    requests.discard(chromecast_media_command::Pause);
    CHECK(requests.next_deadline() == VLC_TICK_FROM_SEC(30));
    requests.discard(chromecast_media_command::Status);
    CHECK(requests.next_deadline() == VLC_TICK_FROM_SEC(50));

    CHECK(chromecast_deadline(VLC_TICK_FROM_SEC(1), 6000)
          == VLC_TICK_FROM_SEC(7));
    CHECK(chromecast_deadline(VLC_TICK_MAX - 1, 6000) == VLC_TICK_MAX);
}

static void check_numeric_ids()
{
    unsigned request_id = 0;
    CHECK(chromecast_request_id_value(0., &request_id) && request_id == 0);
    CHECK(chromecast_request_id_value(42., &request_id) && request_id == 42);
    CHECK(!chromecast_request_id_value(-1., &request_id));
    CHECK(!chromecast_request_id_value(1.5, &request_id));
    CHECK(!chromecast_request_id_value(NAN, &request_id));
    CHECK(!chromecast_request_id_value(INFINITY, &request_id));
    CHECK(!chromecast_request_id_value(
        static_cast<double>(std::numeric_limits<unsigned>::max()) + 1.,
        &request_id));

    int64_t session_id = 0;
    CHECK(chromecast_media_session_id_value(1., &session_id)
          && session_id == 1);
    CHECK(!chromecast_media_session_id_value(0., &session_id));
    CHECK(!chromecast_media_session_id_value(-1., &session_id));
    CHECK(!chromecast_media_session_id_value(1.5, &session_id));
    CHECK(!chromecast_media_session_id_value(NAN, &session_id));
    CHECK(!chromecast_media_session_id_value(INFINITY, &session_id));
    CHECK(!chromecast_media_session_id_value(std::ldexp(1., 63), &session_id));
}

static void check_receiver_clock()
{
    chromecast_media_clock clock;
    CHECK(!clock.valid());
    CHECK(clock.get(10) == VLC_TICK_INVALID);

    const vlc_tick_t sample = VLC_TICK_FROM_SEC(100);
    CHECK(clock.update(0., 1., "PLAYING", sample));
    CHECK(clock.valid());
    CHECK(clock.get(sample) == VLC_TICK_0);
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(2)) == VLC_TICK_FROM_SEC(2));

    CHECK(clock.update(10., .5, "PLAYING", sample));
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(4)) == VLC_TICK_FROM_SEC(12));
    CHECK(clock.update(10., 2., "PLAYING", sample));
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(3)) == VLC_TICK_FROM_SEC(16));
    CHECK(clock.update(10., 0., "PLAYING", sample));
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(3)) == VLC_TICK_FROM_SEC(10));

    CHECK(clock.update(20., 1., "PAUSED", sample));
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(10)) == VLC_TICK_FROM_SEC(20));
    CHECK(clock.update(30., 1., "BUFFERING", sample));
    CHECK(clock.get(sample + VLC_TICK_FROM_SEC(10)) == VLC_TICK_FROM_SEC(30));

    const vlc_tick_t retained = clock.get(sample);
    CHECK(!clock.update(-1., 1., "PLAYING", sample));
    CHECK(!clock.update(NAN, 1., "PLAYING", sample));
    CHECK(!clock.update(INFINITY, 1., "PLAYING", sample));
    CHECK(!clock.update(1., -1., "PLAYING", sample));
    CHECK(!clock.update(1., NAN, "PLAYING", sample));
    CHECK(!clock.update(1., INFINITY, "PLAYING", sample));
    CHECK(!clock.update(std::numeric_limits<double>::max(), 1., "PLAYING",
                        sample));
    CHECK(clock.get(sample) == retained);

    CHECK(clock.update(1., std::numeric_limits<double>::max(), "PLAYING",
                       sample));
    CHECK(clock.get(sample + 1) == VLC_TICK_INVALID);
    clock.clear();
    CHECK(!clock.valid());
    CHECK(clock.get(sample) == VLC_TICK_INVALID);
}

static void check_timeout_and_envelope()
{
    CHECK(CHROMECAST_MESSAGE_MAX_SIZE == 64u * 1024u);
    CHECK(CHROMECAST_WRITE_TIMEOUT_MS == 2000);
    CHECK(chromecast_remaining_timeout_ms(0, 0, 6000) == 6000);
    CHECK(chromecast_remaining_timeout_ms(
              0, VLC_TICK_FROM_MS(1250), 6000) == 4750);
    CHECK(chromecast_remaining_timeout_ms(
              0, VLC_TICK_FROM_MS(6000), 6000) == 0);
    CHECK(chromecast_remaining_timeout_ms(
              0, VLC_TICK_FROM_MS(9000), 6000) == 0);
}

static void check_progress_watchdog()
{
    chromecast_progress_watchdog watchdog;
    CHECK(watchdog.deadline() == VLC_TICK_INVALID);
    watchdog.arm(VLC_TICK_FROM_SEC(10), 30000);
    CHECK(watchdog.deadline() == VLC_TICK_FROM_SEC(40));

    /* LOADING -> BUFFERING -> LOADING calls arm repeatedly. None may renew
     * the original startup deadline. */
    watchdog.arm(VLC_TICK_FROM_SEC(20), 30000);
    watchdog.arm(VLC_TICK_FROM_SEC(30), 30000);
    CHECK(watchdog.deadline() == VLC_TICK_FROM_SEC(40));
    CHECK(!watchdog.expired(VLC_TICK_FROM_SEC(40) - 1));
    CHECK(watchdog.expired(VLC_TICK_FROM_SEC(40)));
    watchdog.clear();
    CHECK(watchdog.deadline() == VLC_TICK_INVALID);
}

static void check_bounded_write()
{
    vlc_tick_t now = VLC_TICK_FROM_SEC(1);
    size_t write_calls = 0;
    size_t wait_calls = 0;
    CHECK(chromecast_write_all_bounded(
        8, 2000,
        [&write_calls](size_t, size_t remaining) -> ssize_t {
            ++write_calls;
            return remaining > 3 ? 3 : static_cast<ssize_t>(remaining);
        },
        [&wait_calls](int) {
            ++wait_calls;
            return 1;
        },
        [&now] { return now; }));
    CHECK(write_calls == 3);
    CHECK(wait_calls == 0);

    std::mutex controller_lock;
    {
        std::lock_guard<std::mutex> held(controller_lock);
        write_calls = wait_calls = 0;
        errno = 0;
        CHECK(!chromecast_write_all_bounded(
            8, 2000,
            [&write_calls](size_t, size_t) -> ssize_t {
                ++write_calls;
                errno = EAGAIN;
                return -1;
            },
            [&wait_calls](int remaining) {
                ++wait_calls;
                CHECK(remaining == 2000);
                return 0;
            },
            [&now] { return now; }));
        CHECK(errno == ETIMEDOUT);
        CHECK(write_calls == 1);
        CHECK(wait_calls == 1);
    }
    const bool lock_recovered = controller_lock.try_lock();
    CHECK(lock_recovered);
    if (lock_recovered)
        controller_lock.unlock();

    size_t sent = 0;
    write_calls = wait_calls = 0;
    errno = 0;
    CHECK(!chromecast_write_all_bounded(
        8, 2000,
        [&sent, &write_calls](size_t, size_t) -> ssize_t {
            ++write_calls;
            if (sent == 0)
            {
                sent = 2;
                return 2;
            }
            errno = EAGAIN;
            return -1;
        },
        [&wait_calls](int) {
            ++wait_calls;
            return 0;
        },
        [&now] { return now; }));
    CHECK(errno == ETIMEDOUT);
    CHECK(write_calls == 2);
    CHECK(wait_calls == 1);

    write_calls = wait_calls = 0;
    errno = 0;
    CHECK(!chromecast_write_all_bounded(
        8, 2000,
        [&write_calls](size_t, size_t) -> ssize_t {
            ++write_calls;
            if (write_calls > 1)
                return 8;
            errno = EAGAIN;
            return -1;
        },
        [&wait_calls, &now](int) {
            ++wait_calls;
            now += VLC_TICK_FROM_SEC(2);
            return 1;
        },
        [&now] { return now; }));
    CHECK(errno == ETIMEDOUT);
    CHECK(write_calls == 1);
    CHECK(wait_calls == 1);
}

static void check_demux_eof()
{
    int is_empty_calls = 0;
    CHECK(!chromecast_demux_drained_and_empty(
        [] { return VLC_EGENERIC; },
        [&is_empty_calls](bool *) {
            ++is_empty_calls;
            return VLC_SUCCESS;
        }));
    CHECK(is_empty_calls == 0);

    CHECK(!chromecast_demux_drained_and_empty(
        [] { return VLC_SUCCESS; },
        [](bool *) { return VLC_EGENERIC; }));
    CHECK(!chromecast_demux_drained_and_empty(
        [] { return VLC_SUCCESS; },
        [](bool *) { return VLC_SUCCESS; }));
    CHECK(!chromecast_demux_drained_and_empty(
        [] { return VLC_SUCCESS; },
        [](bool *empty) {
            *empty = false;
            return VLC_SUCCESS;
        }));
    CHECK(chromecast_demux_drained_and_empty(
        [] { return VLC_SUCCESS; },
        [](bool *empty) {
            *empty = true;
            return VLC_SUCCESS;
        }));
}

int main()
{
    check_request_attribution();
    check_numeric_ids();
    check_receiver_clock();
    check_timeout_and_envelope();
    check_progress_watchdog();
    check_bounded_write();
    check_demux_eof();
    return failures == 0 ? 0 : 1;
}
