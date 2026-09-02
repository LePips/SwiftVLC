#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "modules/video_output/apple/VLCSampleBufferRendererRecovery.h"

#define CHECK(condition)                                                       \
    do                                                                         \
    {                                                                          \
        if (!(condition))                                                      \
        {                                                                      \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition);      \
            exit(EXIT_FAILURE);                                                \
        }                                                                      \
    } while (0)

typedef struct
{
    uint64_t episode;
    uint64_t recovered;
    uint64_t flushes;
    uint64_t revocation_flushes;
    uint64_t failure_flushes;
    uint64_t submissions;
    uint64_t permanent_failures;
    bool flush_latched;
    bool failure_latched;
} model_state;

static void increment(uint64_t *value)
{
    if (*value != UINT64_MAX)
        ++*value;
}

static vlc_samplebuffer_renderer_gate
model_evaluate(model_state *state, bool requires_flush, bool failed)
{
    if (requires_flush || failed)
    {
        if (!state->flush_latched)
        {
            state->flush_latched = true;
            state->failure_latched = false;
            increment(&state->episode);
            increment(&state->flushes);
            if (requires_flush)
                increment(&state->revocation_flushes);
            else
                increment(&state->failure_flushes);
            return VLC_SAMPLEBUFFER_RENDERER_FLUSH_REQUIRED;
        }
        if (!requires_flush)
        {
            if (!state->failure_latched)
            {
                state->failure_latched = true;
                increment(&state->permanent_failures);
            }
            return VLC_SAMPLEBUFFER_RENDERER_PERMANENT_FAILURE;
        }
        return VLC_SAMPLEBUFFER_RENDERER_RETRYABLE;
    }

    state->flush_latched = false;
    state->failure_latched = false;
    return VLC_SAMPLEBUFFER_RENDERER_READY;
}

static bool model_submission(model_state *state)
{
    if (state->episode == state->recovered)
        return false;
    state->recovered = state->episode;
    increment(&state->submissions);
    return true;
}

static void model_reset(model_state *state)
{
    state->recovered = state->episode;
    state->flush_latched = false;
    state->failure_latched = false;
}

static void compare_states(
    const vlc_samplebuffer_renderer_recovery_state *actual,
    const model_state *expected)
{
    CHECK(actual->recovery_episode == expected->episode);
    CHECK(actual->recovered_episode == expected->recovered);
    CHECK(actual->recovery_flush_count == expected->flushes);
    CHECK(actual->revocation_flush_count == expected->revocation_flushes);
    CHECK(actual->failure_flush_count == expected->failure_flushes);
    CHECK(actual->recovery_submission_count == expected->submissions);
    CHECK(actual->permanent_failure_count == expected->permanent_failures);
    CHECK(actual->recovery_flush_latched == expected->flush_latched);
    CHECK(actual->permanent_failure_latched == expected->failure_latched);
}

enum action
{
    ACTION_READY,
    ACTION_FAILED,
    ACTION_REQUIRES_FLUSH,
    ACTION_REQUIRES_FLUSH_AND_FAILED,
    ACTION_SUBMISSION,
    ACTION_RESET,
    ACTION_COUNT,
};

static void apply_action(
    vlc_samplebuffer_renderer_recovery_state *actual,
    model_state *expected, enum action action)
{
    if (action <= ACTION_REQUIRES_FLUSH_AND_FAILED)
    {
        bool requires_flush = action == ACTION_REQUIRES_FLUSH ||
                              action == ACTION_REQUIRES_FLUSH_AND_FAILED;
        bool failed = action == ACTION_FAILED ||
                      action == ACTION_REQUIRES_FLUSH_AND_FAILED;
        vlc_samplebuffer_renderer_gate actual_gate =
            vlc_samplebuffer_renderer_evaluate(actual, requires_flush, failed);
        vlc_samplebuffer_renderer_gate expected_gate =
            model_evaluate(expected, requires_flush, failed);
        CHECK(actual_gate == expected_gate);
    }
    else if (action == ACTION_SUBMISSION)
    {
        CHECK(vlc_samplebuffer_renderer_record_submission(actual) ==
              model_submission(expected));
    }
    else
    {
        vlc_samplebuffer_renderer_reset_boundary(actual);
        model_reset(expected);
    }
    compare_states(actual, expected);
}

static uint64_t exhaustive_paths;

static void exhaustive(
    vlc_samplebuffer_renderer_recovery_state actual,
    model_state expected, unsigned depth)
{
    if (depth == 0)
    {
        ++exhaustive_paths;
        return;
    }

    for (enum action action = ACTION_READY; action < ACTION_COUNT; ++action)
    {
        vlc_samplebuffer_renderer_recovery_state next_actual = actual;
        model_state next_expected = expected;
        apply_action(&next_actual, &next_expected, action);
        exhaustive(next_actual, next_expected, depth - 1);
    }
}

static void test_named_transitions(void)
{
    vlc_samplebuffer_renderer_recovery_state state = { 0 };

    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, false) ==
          VLC_SAMPLEBUFFER_RENDERER_READY);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, true, true) ==
          VLC_SAMPLEBUFFER_RENDERER_FLUSH_REQUIRED);
    CHECK(state.recovery_episode == 1);
    CHECK(state.recovery_flush_count == 1);
    CHECK(state.revocation_flush_count == 1);
    CHECK(state.failure_flush_count == 0);
    CHECK(state.permanent_failure_count == 0);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, true, true) ==
          VLC_SAMPLEBUFFER_RENDERER_RETRYABLE);
    CHECK(state.recovery_flush_count == 1);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, false) ==
          VLC_SAMPLEBUFFER_RENDERER_READY);
    CHECK(vlc_samplebuffer_renderer_record_submission(&state));
    CHECK(!vlc_samplebuffer_renderer_record_submission(&state));
    CHECK(state.recovered_episode == 1);
    CHECK(state.recovery_submission_count == 1);

    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, true) ==
          VLC_SAMPLEBUFFER_RENDERER_FLUSH_REQUIRED);
    CHECK(state.failure_flush_count == 1);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, true) ==
          VLC_SAMPLEBUFFER_RENDERER_PERMANENT_FAILURE);
    CHECK(state.permanent_failure_count == 1);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, true) ==
          VLC_SAMPLEBUFFER_RENDERER_PERMANENT_FAILURE);
    CHECK(state.permanent_failure_count == 1);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, false) ==
          VLC_SAMPLEBUFFER_RENDERER_READY);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, true) ==
          VLC_SAMPLEBUFFER_RENDERER_FLUSH_REQUIRED);
    CHECK(state.failure_flush_count == 2);
    CHECK(state.permanent_failure_count == 1);

    vlc_samplebuffer_renderer_reset_boundary(&state);
    CHECK(state.recovered_episode == state.recovery_episode);
    CHECK(!state.recovery_flush_latched);
    CHECK(!state.permanent_failure_latched);
}

static void test_saturation(void)
{
    uint64_t value = UINT64_MAX;
    vlc_samplebuffer_renderer_increment(&value);
    CHECK(value == UINT64_MAX);

    vlc_samplebuffer_renderer_recovery_state state = {
        .recovery_episode = UINT64_MAX,
        .recovered_episode = UINT64_MAX - 1,
        .recovery_flush_count = UINT64_MAX,
        .revocation_flush_count = UINT64_MAX,
        .failure_flush_count = UINT64_MAX,
        .recovery_submission_count = UINT64_MAX,
        .permanent_failure_count = UINT64_MAX,
    };
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, true, true) ==
          VLC_SAMPLEBUFFER_RENDERER_FLUSH_REQUIRED);
    CHECK(state.recovery_episode == UINT64_MAX);
    CHECK(state.recovery_flush_count == UINT64_MAX);
    CHECK(state.revocation_flush_count == UINT64_MAX);
    CHECK(state.failure_flush_count == UINT64_MAX);
    CHECK(vlc_samplebuffer_renderer_record_submission(&state));
    CHECK(state.recovered_episode == UINT64_MAX);
    CHECK(state.recovery_submission_count == UINT64_MAX);
    CHECK(vlc_samplebuffer_renderer_evaluate(&state, false, true) ==
          VLC_SAMPLEBUFFER_RENDERER_PERMANENT_FAILURE);
    CHECK(state.permanent_failure_count == UINT64_MAX);
}

static void test_randomized(void)
{
    vlc_samplebuffer_renderer_recovery_state actual = { 0 };
    model_state expected = { 0 };
    uint64_t random = UINT64_C(0x8a5cd789635d2dff);
    for (uint64_t iteration = 0; iteration < UINT64_C(1000000); ++iteration)
    {
        random ^= random << 13;
        random ^= random >> 7;
        random ^= random << 17;
        apply_action(&actual, &expected,
                     (enum action)(random % ACTION_COUNT));
    }
}

int main(void)
{
    test_named_transitions();
    test_saturation();
    exhaustive((vlc_samplebuffer_renderer_recovery_state){ 0 },
               (model_state){ 0 }, 8);
    CHECK(exhaustive_paths == UINT64_C(1679616));
    test_randomized();
    printf("PASS renderer recovery: exhaustive=%" PRIu64
           " randomized=1000000\n", exhaustive_paths);
    return EXIT_SUCCESS;
}
