#ifndef SWIFTVLC_UPNP_FAKE_VLC_COMMON_H
#define SWIFTVLC_UPNP_FAKE_VLC_COMMON_H

#include <climits>
#include <cstdlib>
#include <cstring>
#include <ifaddrs.h>
#include <net/if.h>

#define VLC_API
#define VLC_USED
#define likely(value) (value)
#define unlikely(value) (value)
#define msg_Info(...) ((void)0)
#define msg_Err(...) ((void)0)

struct vlc_object_t
{
    int unused;
};

extern "C" char *var_InheritString(vlc_object_t *, const char *);

#endif
