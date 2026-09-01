#include <stddef.h>
#include <vlc/vlc.h>

_Static_assert(sizeof(((libvlc_event_t *)0)->u) == 24,
               "released event union size changed");
_Static_assert(sizeof(libvlc_event_t) == 40,
               "released event envelope size changed");
_Static_assert(offsetof(libvlc_event_t, u) == 16,
               "released event payload offset changed");
_Static_assert(libvlc_MediaPlayerRateChanged ==
                   libvlc_MediaPlayerFrameStepCompleted + 1,
               "effective-rate event was not append-only");
_Static_assert(libvlc_MediaListItemAdded == 0x200,
               "media-list event range moved");
_Static_assert(
    sizeof(((libvlc_event_t *)0)->u.media_player_rate_changed) == 4,
    "effective-rate payload size changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_rate_changed.new_rate) == 16,
    "effective-rate payload offset changed");
_Static_assert(offsetof(libvlc_event_t,
    u.media_player_frame_step_completed.position) == 36,
    "preceding strict frame-step ABI moved");

static float consume_rate(const libvlc_event_t *event)
{
    return event->type == libvlc_MediaPlayerRateChanged
         ? event->u.media_player_rate_changed.new_rate : 0.f;
}

int main(void)
{
    libvlc_event_t event = {
        .type = libvlc_MediaPlayerRateChanged,
        .u.media_player_rate_changed.new_rate = 1.25f,
    };
    return consume_rate(&event) == 1.25f ? 0 : 1;
}
