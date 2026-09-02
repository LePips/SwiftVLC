/* Linked production-path proof for SwiftVLC patch 0028. */

#include <cstdio>
#include <cstring>
#include <string>
#include <string_view>

#include "chromecast_demux_duration.hpp"
#include "chromecast_protocol.hpp"

#define CHECK(condition, message)                                              \
    do                                                                         \
    {                                                                          \
        if (!(condition))                                                      \
        {                                                                      \
            std::fprintf(stderr,                                               \
                         "post-pin stability probe failed: %s\n", message);    \
            return 1;                                                          \
        }                                                                      \
    } while (0)

struct parser_input
{
    const char *cursor;
    unsigned errors;
};

extern "C" size_t json_read(void *opaque, void *buffer, size_t maximum)
{
    parser_input *input = static_cast<parser_input *>(opaque);
    const size_t remaining = std::strlen(input->cursor);
    const size_t count = remaining < maximum ? remaining : maximum;
    std::memcpy(buffer, input->cursor, count);
    input->cursor += count;
    return count;
}

extern "C" void json_parse_error(void *opaque, const char *)
{
    parser_input *input = static_cast<parser_input *>(opaque);
    ++input->errors;
}

static bool parse_object(const char *payload, json_object *result)
{
    parser_input input = { payload, 0 };
    const int status = json_parse(&input, result);
    return status == 0 && input.errors == 0;
}

static int check_type(const char *payload, std::string_view expected)
{
    json_object object;
    if (!parse_object(payload, &object))
        return 1;
    const std::string_view actual = json_get_str_view(&object, "type");
    const bool matches = actual == expected;
    json_free(&object);
    return matches ? 0 : 1;
}

int main()
{
    json_object object;
    CHECK(parse_object("{}", &object), "root object must parse");
    CHECK(json_get_str_view(&object, "type").empty(),
          "missing type must produce an empty view");
    json_free(&object);

    CHECK(!parse_object("[]", &object),
          "root array must be rejected by VLC's object-message parser");
    CHECK(check_type("{\"type\":42}", "") == 0,
          "non-string type must produce an empty view");
    CHECK(check_type("{\"type\":{}}", "") == 0,
          "object-valued type must produce an empty view");
    CHECK(check_type("{\"type\":\"CLOSE\"}", "CLOSE") == 0,
          "root CLOSE must survive production parsing");

    CHECK(check_type("{\"type\":\"PING\"}", "PING") == 0,
          "heartbeat namespace type mismatch");
    CHECK(check_type("{\"type\":\"RECEIVER_STATUS\"}",
                     "RECEIVER_STATUS") == 0,
          "receiver namespace type mismatch");
    CHECK(check_type("{\"type\":\"MEDIA_STATUS\"}", "MEDIA_STATUS") == 0,
          "media namespace type mismatch");
    CHECK(check_type("{\"type\":\"CONNECT\"}", "CONNECT") == 0,
          "ordinary connection namespace type mismatch");

    const std::string ipv4 =
        chromecast_server_base_url("192.0.2.10", 8010);
    CHECK(ipv4 == "http://192.0.2.10:8010",
          "production IPv4 URL serialization changed");
    CHECK(chromecast_server_base_url("0.0.0.0", 8010).empty()
       && chromecast_server_base_url("127.0.0.1", 8010).empty()
       && chromecast_server_base_url("127.42.0.7", 8010).empty()
       && chromecast_server_base_url("224.0.0.1", 8010).empty()
       && chromecast_server_base_url("239.255.255.250", 8010).empty(),
          "unreachable IPv4 classes must fail closed");

    const std::string ipv6 =
        chromecast_server_base_url("2001:db8::1234", 8010);
    CHECK(ipv6 == "http://[2001:db8::1234]:8010",
          "global IPv6 must be bracketed by production vlc_uri_compose");
    CHECK(chromecast_server_base_url("2001:db8::1234%en0", 8010).empty(),
          "scoped global IPv6 must fail closed");
    CHECK(chromecast_server_base_url("fe80::1234", 8010).empty(),
          "unscoped link-local IPv6 must fail closed");
    CHECK(chromecast_server_base_url("fe80::1234%en0", 8010).empty(),
          "scoped link-local IPv6 must fail closed");
    CHECK(chromecast_server_base_url("::", 8010).empty()
       && chromecast_server_base_url("::1", 8010).empty()
       && chromecast_server_base_url("ff02::1", 8010).empty(),
          "unspecified/loopback/multicast IPv6 must fail closed");
    CHECK(chromecast_server_base_url("::ffff:0.0.0.0", 8010).empty()
       && chromecast_server_base_url("::ffff:127.0.0.1", 8010).empty()
       && chromecast_server_base_url("::ffff:224.0.0.1", 8010).empty(),
          "IPv4-mapped unreachable classes must fail closed");
    CHECK(!chromecast_server_base_url("::ffff:192.0.2.10", 8010).empty(),
          "publishable IPv4-mapped IPv6 must remain usable");

    const std::string artwork_path = "/chromecast/art/7";
    const std::string source_artwork = "file:///tmp/cover.jpg";
    const std::string old_artwork = chromecast_artwork_url(
        "http://192.0.2.10:8010", artwork_path);
    /* reinit() is structurally required to execute these production helpers
     * in this order: restore the tracked old publication, invalidate the old
     * base, obtain a new publishable base, then prepare/publish again. */
    const std::string restored_artwork =
        chromecast_restore_wrapped_artwork_url(
            old_artwork, source_artwork, old_artwork);
    const std::string new_artwork = chromecast_artwork_url(
        "http://192.0.2.11:8010", artwork_path);
    CHECK(restored_artwork == source_artwork
       && new_artwork == "http://192.0.2.11:8010/chromecast/art/7"
       && new_artwork.find("192.0.2.10") == std::string::npos,
          "old route must restore source artwork before new-route publication");
    CHECK(chromecast_restore_wrapped_artwork_url(
              "https://example.test/cover.jpg", source_artwork, old_artwork)
              == "https://example.test/cover.jpg",
          "external artwork must never be mistaken for wrapper metadata");
    CHECK(chromecast_artwork_url("", artwork_path).empty(),
          "artwork publication must fail closed without a route");

    unsigned duration_queries = 0;
    const auto query_duration = [&](int result, vlc_tick_t duration, bool live) {
        return chromecast_query_demux_input_length(
            [&](vlc_tick_t *out_duration, bool *out_live) {
                ++duration_queries;
                *out_duration = duration;
                *out_live = live;
                return result;
            });
    };
    CHECK(query_duration(VLC_EGENERIC, VLC_TICK_FROM_SEC(60), true)
              == VLC_TICK_INVALID,
          "failed DEMUX_GET_LENGTH must remain unknown");
    CHECK(query_duration(VLC_SUCCESS, VLC_TICK_INVALID, false)
              == VLC_TICK_INVALID,
          "successful unknown non-live duration must remain unknown");
    CHECK(query_duration(VLC_SUCCESS, VLC_TICK_FROM_SEC(60), true)
              == INPUT_DURATION_INDEFINITE,
          "positive live seek range must classify as indefinite");
    CHECK(query_duration(VLC_SUCCESS, VLC_TICK_INVALID, true)
              == INPUT_DURATION_INDEFINITE,
          "zero-length live stream must classify as indefinite");
    CHECK(query_duration(VLC_SUCCESS, VLC_TICK_FROM_SEC(60), false)
              == VLC_TICK_FROM_SEC(60),
          "finite non-live duration must remain buffered duration");
    CHECK(duration_queries == 5,
          "duration cases did not execute the production query branch");

    const std::string content_id = ipv6 + "/stream";
    const std::string unknown =
        chromecast_media_fields(content_id, "video/mp4", VLC_TICK_INVALID);
    CHECK(unknown.find("\"streamType\":\"NONE\"") != std::string::npos
       && unknown.find("\"duration\"") == std::string::npos,
          "unknown duration must use NONE without duration");

    const std::string live = chromecast_media_fields(
        content_id, "video/mp4", INPUT_DURATION_INDEFINITE);
    CHECK(live.find("\"streamType\":\"LIVE\"") != std::string::npos
       && live.find("\"duration\"") == std::string::npos,
          "indefinite duration must use LIVE without duration");

    const std::string buffered =
        chromecast_media_fields(content_id, "video/mp4", 12500000);
    CHECK(buffered.find("\"streamType\":\"BUFFERED\"") != std::string::npos
       && buffered.find("\"duration\":12.500000") != std::string::npos,
          "finite media must use BUFFERED with fixed duration");
    CHECK(chromecast_media_fields("", "video/mp4", 12500000).empty(),
          "empty/unreachable content URL must fail closed");

    const std::string load = chromecast_load_payload(buffered, 17);
    CHECK(load.find("\"type\":\"LOAD\"") != std::string::npos
       && load.find("\"requestId\":17") != std::string::npos,
          "production LOAD payload mismatch");
    CHECK(load.find("autoplay") == std::string::npos,
          "invalid autoplay attribute reappeared");
    CHECK(chromecast_load_payload("", 18).empty(),
          "LOAD must fail closed when media fields are unavailable");

    std::puts("post-pin stability linked production probe passed");
    return 0;
}
