#include <cstddef>
#include <type_traits>
#include <vlc/vlc.h>

static_assert(sizeof(libvlc_event_t) == 40);
static_assert(offsetof(libvlc_event_t, u) == 16);
static_assert(libvlc_MediaPlayerRateChanged ==
              libvlc_MediaPlayerFrameStepCompleted + 1);
static_assert(sizeof(libvlc_event_t{}.u.media_player_rate_changed) == 4);
static_assert(offsetof(libvlc_event_t,
              u.media_player_rate_changed.new_rate) == 16);
static_assert(std::is_same_v<
              decltype(libvlc_event_t{}.u.media_player_rate_changed.new_rate),
              float>);

int main()
{
    libvlc_event_t event{};
    event.type = libvlc_MediaPlayerRateChanged;
    event.u.media_player_rate_changed.new_rate = 2.f;
    return event.u.media_player_rate_changed.new_rate == 2.f ? 0 : 1;
}
