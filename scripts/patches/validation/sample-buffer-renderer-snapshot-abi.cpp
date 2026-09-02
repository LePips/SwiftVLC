#include <cstddef>
#include <cstdint>
#include <type_traits>

#include <vlc/vlc.h>

static_assert(sizeof(swiftvlc_sample_buffer_renderer_snapshot_t) == 136);
static_assert(alignof(swiftvlc_sample_buffer_renderer_snapshot_t) == 8);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       abi_version) == 0);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t, flags) ==
              4);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       display_generation) == 8);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       recovery_episode_count) == 16);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       recovered_episode_count) == 24);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       requirement_notification_count) == 32);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       revocation_notification_count) == 40);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       decode_failure_notification_count) == 48);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       foreground_check_count) == 56);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       recovery_flush_count) == 64);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       revocation_flush_count) == 72);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       failure_flush_count) == 80);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       discontinuity_flush_count) == 88);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       successful_submission_count) == 96);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       recovery_submission_count) == 104);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       retryable_submission_count) == 112);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       recovery_sample_failure_count) == 120);
static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                       permanent_failure_count) == 128);
static_assert(std::is_standard_layout_v<
              swiftvlc_sample_buffer_renderer_snapshot_t>);

static bool (*const snapshot_function)(
    libvlc_media_player_t *, swiftvlc_sample_buffer_renderer_snapshot_t *) =
    swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot;

int main()
{
    return snapshot_function == nullptr;
}
