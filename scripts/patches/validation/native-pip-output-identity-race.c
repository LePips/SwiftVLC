/* Portable concurrency model for the v9 native PiP identity/token contract. */
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CLAIMED_TOKEN UINT64_MAX

enum {
    allocator_threads = 8,
    allocations_per_thread = 20000,
    token_race_iterations = 1000,
};

struct exact_identity
{
    uint64_t native_handle;
    uint64_t playback_generation;
    uint64_t output_identity;
};

struct binding_state
{
    struct exact_identity identity;
    atomic_uint_fast64_t preparation_token;
    atomic_uint_fast64_t handoff_token;
    atomic_bool closed;
};

static bool identities_equal(struct exact_identity lhs,
                             struct exact_identity rhs)
{
    return lhs.native_handle == rhs.native_handle &&
           lhs.playback_generation == rhs.playback_generation &&
           lhs.output_identity == rhs.output_identity;
}

static uint64_t next_output_identity(atomic_uint_fast64_t *source)
{
    uint_fast64_t current =
        atomic_load_explicit(source, memory_order_relaxed);
    for (;;)
    {
        if (current >= UINT64_MAX - 1)
        {
            if (current == UINT64_MAX - 1)
                atomic_compare_exchange_strong_explicit(
                    source, &current, UINT64_MAX, memory_order_relaxed,
                    memory_order_relaxed);
            return 0;
        }
        uint_fast64_t next = current + 1;
        if (atomic_compare_exchange_weak_explicit(
                source, &current, next, memory_order_relaxed,
                memory_order_relaxed))
            return next;
    }
}

struct allocator_context
{
    atomic_uint_fast64_t *source;
    uint64_t *outputs;
    size_t offset;
};

static void *allocate_outputs(void *opaque)
{
    struct allocator_context *context = opaque;
    for (size_t index = 0; index < allocations_per_thread; ++index)
        context->outputs[context->offset + index] =
            next_output_identity(context->source);
    return NULL;
}

static int compare_u64(const void *lhs, const void *rhs)
{
    uint64_t a = *(const uint64_t *)lhs;
    uint64_t b = *(const uint64_t *)rhs;
    return (a > b) - (a < b);
}

static bool claim_preparation(struct binding_state *state,
                              struct exact_identity identity,
                              uint_fast64_t replacement)
{
    if (!identities_equal(state->identity, identity) ||
        atomic_load_explicit(&state->closed, memory_order_acquire))
        return false;
    uint_fast64_t expected = identity.output_identity;
    if (!atomic_compare_exchange_strong_explicit(
            &state->preparation_token, &expected, replacement,
            memory_order_acq_rel, memory_order_acquire))
        return false;
    if (replacement == CLAIMED_TOKEN)
        atomic_store_explicit(&state->closed, true, memory_order_release);
    return true;
}

static bool claim_handoff(struct binding_state *state,
                          struct exact_identity identity)
{
    if (!identities_equal(state->identity, identity) ||
        atomic_load_explicit(&state->closed, memory_order_acquire))
        return false;
    uint_fast64_t expected = identity.output_identity;
    return atomic_compare_exchange_strong_explicit(
        &state->handoff_token, &expected, CLAIMED_TOKEN,
        memory_order_acq_rel, memory_order_acquire);
}

enum token_operation
{
    ready_operation,
    preparation_timeout_operation,
    successor_take_operation,
    handoff_timeout_operation,
};

struct token_race_context
{
    struct binding_state *state;
    struct exact_identity identity;
    enum token_operation operation;
    atomic_bool *start;
    atomic_uint *winners;
};

static void *run_token_operation(void *opaque)
{
    struct token_race_context *context = opaque;
    while (!atomic_load_explicit(context->start, memory_order_acquire))
        sched_yield();

    bool won = false;
    switch (context->operation)
    {
        case ready_operation:
            won = claim_preparation(context->state, context->identity, 0);
            break;
        case preparation_timeout_operation:
            won = claim_preparation(context->state, context->identity,
                                    CLAIMED_TOKEN);
            break;
        case successor_take_operation:
        case handoff_timeout_operation:
            won = claim_handoff(context->state, context->identity);
            break;
    }
    if (won)
        atomic_fetch_add_explicit(context->winners, 1, memory_order_relaxed);
    return NULL;
}

static bool run_two_way_race(struct binding_state *state,
                             struct exact_identity identity,
                             enum token_operation first,
                             enum token_operation second)
{
    atomic_bool start = ATOMIC_VAR_INIT(false);
    atomic_uint winners = ATOMIC_VAR_INIT(0);
    struct token_race_context contexts[2] = {
        { state, identity, first, &start, &winners },
        { state, identity, second, &start, &winners },
    };
    pthread_t threads[2];
    if (pthread_create(&threads[0], NULL, run_token_operation, &contexts[0]) ||
        pthread_create(&threads[1], NULL, run_token_operation, &contexts[1]))
        return false;
    atomic_store_explicit(&start, true, memory_order_release);
    pthread_join(threads[0], NULL);
    pthread_join(threads[1], NULL);
    return atomic_load_explicit(&winners, memory_order_relaxed) == 1;
}

static bool test_allocator(void)
{
    const size_t count = allocator_threads * allocations_per_thread;
    uint64_t *outputs = calloc(count, sizeof(*outputs));
    if (outputs == NULL)
        return false;

    atomic_uint_fast64_t source = ATOMIC_VAR_INIT(0);
    pthread_t threads[allocator_threads];
    struct allocator_context contexts[allocator_threads];
    for (size_t index = 0; index < allocator_threads; ++index)
    {
        contexts[index] = (struct allocator_context) {
            .source = &source,
            .outputs = outputs,
            .offset = index * allocations_per_thread,
        };
        if (pthread_create(&threads[index], NULL, allocate_outputs,
                           &contexts[index]))
        {
            free(outputs);
            return false;
        }
    }
    for (size_t index = 0; index < allocator_threads; ++index)
        pthread_join(threads[index], NULL);

    qsort(outputs, count, sizeof(*outputs), compare_u64);
    bool valid = outputs[0] != 0;
    for (size_t index = 1; valid && index < count; ++index)
        valid = outputs[index] != 0 && outputs[index] != outputs[index - 1];
    free(outputs);
    if (!valid)
        return false;

    atomic_uint_fast64_t saturated = ATOMIC_VAR_INIT(UINT64_MAX - 3);
    if (next_output_identity(&saturated) != UINT64_MAX - 2 ||
        next_output_identity(&saturated) != UINT64_MAX - 1 ||
        next_output_identity(&saturated) != 0 ||
        next_output_identity(&saturated) != 0 ||
        atomic_load_explicit(&saturated, memory_order_relaxed) != UINT64_MAX)
        return false;
    return true;
}

static bool test_exact_tokens(void)
{
    const struct exact_identity a = { 11, 21, 31 };
    const struct exact_identity b = { 12, 22, 32 };
    for (unsigned iteration = 0; iteration < token_race_iterations; ++iteration)
    {
        struct binding_state preparation = {
            .identity = b,
            .preparation_token = ATOMIC_VAR_INIT(32),
            .handoff_token = ATOMIC_VAR_INIT(0),
            .closed = ATOMIC_VAR_INIT(false),
        };
        if (!run_two_way_race(&preparation, b, ready_operation,
                              preparation_timeout_operation))
            return false;

        struct binding_state handoff = {
            .identity = a,
            .preparation_token = ATOMIC_VAR_INIT(0),
            .handoff_token = ATOMIC_VAR_INIT(31),
            .closed = ATOMIC_VAR_INIT(false),
        };
        if (!run_two_way_race(&handoff, a, successor_take_operation,
                              handoff_timeout_operation))
            return false;
    }

    /* A delayed timeout cannot claim B after the controller has rebound. */
    struct binding_state rebound = {
        .identity = b,
        .preparation_token = ATOMIC_VAR_INIT(32),
        .handoff_token = ATOMIC_VAR_INIT(0),
        .closed = ATOMIC_VAR_INIT(false),
    };
    if (claim_preparation(&rebound, a, CLAIMED_TOKEN) ||
        !claim_preparation(&rebound, b, 0) ||
        claim_preparation(&rebound, b, CLAIMED_TOKEN))
        return false;

    /* A close before prepare wins once; its later timer and ready both lose. */
    struct binding_state closed_before_prepare = {
        .identity = b,
        .preparation_token = ATOMIC_VAR_INIT(32),
        .handoff_token = ATOMIC_VAR_INIT(0),
        .closed = ATOMIC_VAR_INIT(false),
    };
    if (!claim_preparation(&closed_before_prepare, b, CLAIMED_TOKEN) ||
        claim_preparation(&closed_before_prepare, b, CLAIMED_TOKEN) ||
        claim_preparation(&closed_before_prepare, b, 0))
        return false;
    return true;
}

int main(void)
{
    if (!test_allocator())
    {
        fputs("native PiP output identity allocator race failed\n", stderr);
        return 1;
    }
    if (!test_exact_tokens())
    {
        fputs("native PiP exact token race failed\n", stderr);
        return 1;
    }
    puts("native PiP output identity race model passed");
    return 0;
}
