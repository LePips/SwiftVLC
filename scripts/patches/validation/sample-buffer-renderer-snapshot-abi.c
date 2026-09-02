#include <stddef.h>
#include <stdint.h>

#include <vlc/vlc.h>

_Static_assert(swiftvlc_sample_buffer_renderer_current == (1u << 0),
               "current flag ABI");
_Static_assert(swiftvlc_sample_buffer_renderer_requires_flush == (1u << 1),
               "requires-flush flag ABI");
_Static_assert(swiftvlc_sample_buffer_renderer_failed == (1u << 2),
               "failed flag ABI");
_Static_assert(swiftvlc_sample_buffer_renderer_recovery_in_progress ==
                   (1u << 3),
               "recovery flag ABI");
_Static_assert(swiftvlc_sample_buffer_renderer_recovery_sample_available ==
                   (1u << 4),
               "recovery sample flag ABI");

_Static_assert(sizeof(swiftvlc_sample_buffer_renderer_snapshot_t) == 136,
               "renderer snapshot ABI size");
_Static_assert(_Alignof(swiftvlc_sample_buffer_renderer_snapshot_t) == 8,
               "renderer snapshot ABI alignment");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        abi_version) == 0,
               "ABI version offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t, flags) == 4,
               "flags offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        display_generation) == 8,
               "generation offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        recovery_episode_count) == 16,
               "recovery episode count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        recovered_episode_count) == 24,
               "recovered episode count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        requirement_notification_count) == 32,
               "requirement notification count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        revocation_notification_count) == 40,
               "revocation notification count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        decode_failure_notification_count) == 48,
               "decode failure notification count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        foreground_check_count) == 56,
               "foreground check count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        recovery_flush_count) == 64,
               "recovery flush count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        revocation_flush_count) == 72,
               "revocation flush count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        failure_flush_count) == 80,
               "failure flush count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        discontinuity_flush_count) == 88,
               "discontinuity flush count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        successful_submission_count) == 96,
               "successful submission count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        recovery_submission_count) == 104,
               "recovery submission count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        retryable_submission_count) == 112,
               "retryable submission count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        recovery_sample_failure_count) == 120,
               "recovery sample failure count offset");
_Static_assert(offsetof(swiftvlc_sample_buffer_renderer_snapshot_t,
                        permanent_failure_count) == 128,
               "terminal field offset");

static bool (*const snapshot_function)(
    libvlc_media_player_t *, swiftvlc_sample_buffer_renderer_snapshot_t *) =
    swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot;

int main(void)
{
    return snapshot_function == NULL;
}
