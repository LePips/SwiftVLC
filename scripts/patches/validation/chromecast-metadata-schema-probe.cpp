/****************************************************************************
 * Native truth-table probe for SwiftVLC patch 0036's metadata parser.
 ****************************************************************************/

#include "chromecast_protocol.hpp"

#include <cstdio>
#include <limits>
#include <string>
#include <string_view>

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

static void check_valid_values()
{
    struct valid_case
    {
        std::string_view input;
        unsigned expected;
    };
    const valid_case cases[] = {
        { "1", 1 },
        { "9", 9 },
        { "42", 42 },
        { "00042", 42 },
    };

    for (const valid_case &test : cases)
    {
        unsigned result = 0;
        CHECK(chromecast_positive_metadata_integer(test.input, &result));
        CHECK(result == test.expected);
    }

    const std::string maximum =
        std::to_string(std::numeric_limits<unsigned>::max());
    unsigned result = 0;
    CHECK(chromecast_positive_metadata_integer(maximum, &result));
    CHECK(result == std::numeric_limits<unsigned>::max());
}

static void check_invalid_values()
{
    const std::string embedded_nul("1\0", 2);
    const std::string non_ascii("\xc2\xa0" "1", 3);
    const std::string very_large(256, '9');
    const std::string overflow =
        std::to_string(std::numeric_limits<unsigned>::max()) + "0";
    const std::string_view cases[] = {
        "",
        "0",
        "0000",
        "+1",
        "-1",
        " 1",
        "1 ",
        "\t1",
        "1\n",
        "1.0",
        "1/12",
        "1e1",
        "12x",
        embedded_nul,
        non_ascii,
        overflow,
        very_large,
    };

    for (const std::string_view test : cases)
    {
        unsigned result = 77;
        CHECK(!chromecast_positive_metadata_integer(test, &result));
        CHECK(result == 77);
    }

    CHECK(!chromecast_positive_metadata_integer("1", nullptr));
}

static void check_metadata_presence_policy()
{
    /* A fallback title is indistinguishable from a primary title at this pure
     * boundary: either must retain generic and music metadata behavior. */
    CHECK(chromecast_should_emit_metadata(false, "NowPlaying", "", "", "",
                                          false, false));
    CHECK(chromecast_should_emit_metadata(true, "NowPlaying", "", "", "",
                                          false, false));

    CHECK(!chromecast_should_emit_metadata(false, "", "artist", "album",
                                           "album artist", true, true));
    CHECK(!chromecast_should_emit_metadata(false, "", "", "", "", false,
                                           false));

    CHECK(chromecast_should_emit_metadata(true, "", "artist", "", "", false,
                                          false));
    CHECK(chromecast_should_emit_metadata(true, "", "", "album", "", false,
                                          false));
    CHECK(chromecast_should_emit_metadata(true, "", "", "", "album artist",
                                          false, false));
    CHECK(chromecast_should_emit_metadata(true, "", "", "", "", true,
                                          false));
    CHECK(chromecast_should_emit_metadata(true, "", "", "", "", false,
                                          true));
    CHECK(!chromecast_should_emit_metadata(true, "", "", "", "", false,
                                           false));
}

int main()
{
    check_valid_values();
    check_invalid_values();
    check_metadata_presence_policy();
    if (failures != 0)
        return 1;
    std::puts("PASS Chromecast 0036 metadata integer truth table");
    return 0;
}
