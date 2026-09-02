/*****************************************************************************
 * Native truth tables for Chromecast 0037 load/generation token semantics.
 *****************************************************************************/

#include "chromecast_common.h"
#include "chromecast_protocol.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <string_view>
#include <type_traits>

#define CHECK(condition)                                                       \
    do                                                                         \
    {                                                                          \
        if (!(condition))                                                      \
        {                                                                      \
            std::fprintf(stderr, "check failed at line %d: %s\n", __LINE__,  \
                         #condition);                                          \
            return 1;                                                          \
        }                                                                      \
    } while (0)

int main()
{
    using namespace std::literals;

    static_assert(std::is_same_v<cc_input_generation_t, uint64_t>);
    static_assert(std::is_same_v<cc_stream_token_t, uint64_t>);
    static_assert(sizeof(cc_input_generation_t) == 8);
    static_assert(sizeof(cc_stream_token_t) == 8);

    const std::array<std::string_view, 4> primary_states{
        "IDLE"sv, "LOADING"sv, "BUFFERING"sv, "PLAYING"sv,
    };
    const std::array<std::string_view, 4> extended_states{
        ""sv, "LOADING"sv, "BUFFERING"sv, "PLAYING"sv,
    };
    const std::array<std::string_view, 6> idle_reasons{
        ""sv, "FINISHED"sv, "CANCELLED"sv,
        "INTERRUPTED"sv, "ERROR"sv, "UNKNOWN"sv,
    };

    unsigned pending_cases = 0;
    for (bool played_once : {false, true})
    {
        for (bool controller_starting : {false, true})
        {
            for (const std::string_view primary : primary_states)
            {
                for (const std::string_view extended : extended_states)
                {
                    for (const std::string_view reason : idle_reasons)
                    {
                        const bool actual =
                            chromecast_initial_load_is_pending(
                                played_once, controller_starting, primary,
                                extended, reason);
                        const bool expected =
                            !played_once && controller_starting
                            && primary == "IDLE"
                            && extended == "LOADING"
                            && reason.empty();
                        CHECK(actual == expected);
                        pending_cases += actual;
                    }
                }
            }
        }
    }
    CHECK(pending_cases == 1);

    CHECK(chromecast_stream_query(0).empty());
    CHECK(chromecast_stream_query(1) == "streamToken=1");
    CHECK(chromecast_stream_query(std::numeric_limits<uint64_t>::max())
        == "streamToken=18446744073709551615");

    CHECK(chromecast_stream_query_matches("streamToken=1", 1));
    CHECK(chromecast_stream_query_matches(
        "streamToken=18446744073709551615",
        std::numeric_limits<uint64_t>::max()));

    const std::array<std::string_view, 16> malformed_queries{
        ""sv,
        "streamToken"sv,
        "streamToken="sv,
        "streamToken=0"sv,
        "streamToken=00"sv,
        "streamToken=01"sv,
        "streamToken=+1"sv,
        "streamToken=-1"sv,
        "streamToken= 1"sv,
        "streamToken=1 "sv,
        "streamToken=1&extra=1"sv,
        "extra=1&streamToken=1"sv,
        "streamtoken=1"sv,
        "streamToken=%31"sv,
        "streamToken=1.0"sv,
        "streamToken=18446744073709551616"sv,
    };
    for (const std::string_view malformed : malformed_queries)
        CHECK(!chromecast_stream_query_matches(malformed, 1));

    CHECK(!chromecast_stream_query_matches("streamToken=2", 1));
    CHECK(!chromecast_stream_query_matches("streamToken=1", 0));
    CHECK(!chromecast_stream_query_matches(
        "streamToken=18446744073709551614",
        std::numeric_limits<uint64_t>::max()));

    /* Exercise the exact decimal grammar and full-width generation/token
     * identity with deterministic, nonzero 64-bit values. */
    uint64_t token = UINT64_C(0x9e3779b97f4a7c15);
    for (unsigned index = 0; index < 100000; ++index)
    {
        token ^= token >> 12;
        token ^= token << 25;
        token ^= token >> 27;
        if (token == 0)
            token = 1;

        const std::string query = chromecast_stream_query(token);
        CHECK(!query.empty());
        CHECK(chromecast_stream_query_matches(query, token));
        CHECK(!chromecast_stream_query_matches(query, token ^ UINT64_C(1)));
    }

    CHECK(chromecast_stream_url(
        "http://192.0.2.1:8010", "/cast", 42)
        == "http://192.0.2.1:8010/cast?streamToken=42");
    CHECK(chromecast_stream_url(
        "http://[2001:db8::1]:8010", "/cast", 42)
        == "http://[2001:db8::1]:8010/cast?streamToken=42");
    CHECK(chromecast_stream_url("", "/cast", 42).empty());
    CHECK(chromecast_stream_url("http://192.0.2.1", "", 42).empty());
    CHECK(chromecast_stream_url("http://192.0.2.1", "/cast", 0).empty());

    return 0;
}
