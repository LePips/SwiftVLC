#include <cstdint>
#include <type_traits>

#include <vlc/vlc.h>

static_assert(SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US == INT64_MIN,
              "invalid vmem picture PTS sentinel changed");
static_assert(!std::is_same_v<swiftvlc_video_display_status_cb,
                              swiftvlc_video_display_status_v2_cb>,
              "v6 must not mutate the version-4 callback typedef");
static_assert(std::is_same_v<
              swiftvlc_video_display_status_cb,
              int (*)(void *, void *)>,
              "version-4 callback ABI changed");
static_assert(std::is_same_v<
              swiftvlc_video_display_status_v2_cb,
              int (*)(void *, void *, std::int64_t)>,
              "version-6 callback ABI changed");

using atomic_v2_function = int (*)(
    libvlc_media_player_t *, libvlc_video_lock_cb, libvlc_video_unlock_cb,
    libvlc_video_display_cb, swiftvlc_video_display_status_v2_cb,
    swiftvlc_video_format_ex_cb, libvlc_video_cleanup_cb, void *);
static_assert(std::is_same_v<
              decltype(&swiftvlc_libvlc_video_set_callbacks_atomic_v2),
              atomic_v2_function>,
              "version-6 atomic setter ABI changed");
