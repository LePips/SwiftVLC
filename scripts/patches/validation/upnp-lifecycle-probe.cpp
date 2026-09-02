/* Compile and execute the production UpnpInstanceWrapper get/release path. */

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

#include "upnp-wrapper.hpp"

namespace {

std::mutex fake_lock;
std::condition_variable fake_changed;
Upnp_FunPtr registered_callback = nullptr;
std::atomic<unsigned> init_calls{0};
std::atomic<unsigned> finish_calls{0};
bool block_finish = true;
bool finish_entered = false;
bool finish_callback_returned = false;
bool allow_finish = false;

[[noreturn]] void fail(const char *message)
{
    std::fprintf(stderr, "UPnP lifecycle probe failed: %s\n", message);
    std::_Exit(1);
}

void require(bool condition, const char *message)
{
    if (!condition)
        fail(message);
}

template <typename Predicate>
void wait_for(Predicate predicate, const char *message)
{
    std::unique_lock<std::mutex> lock(fake_lock);
    if (!fake_changed.wait_for(lock, std::chrono::seconds(2), predicate))
        fail(message);
}

} // namespace

extern "C" char *var_InheritString(vlc_object_t *, const char *)
{
    return ::strdup("probe0");
}

extern "C" int UpnpInit2(const char *, unsigned short)
{
    ++init_calls;
    return UPNP_E_SUCCESS;
}

extern "C" int UpnpRegisterClient(Upnp_FunPtr callback, const void *,
                                   UpnpClient_Handle *handle)
{
    registered_callback = callback;
    *handle = 17;
    return UPNP_E_SUCCESS;
}

extern "C" int UpnpUnRegisterClient(UpnpClient_Handle)
{
    return UPNP_E_SUCCESS;
}

extern "C" int UpnpSetMaxContentLength(size_t)
{
    return UPNP_E_SUCCESS;
}

extern "C" const char *UpnpGetErrorMessage(int)
{
    return "probe";
}

extern "C" void ixmlRelaxParser(char)
{
}

extern "C" int UpnpFinish(void)
{
    const bool should_block = block_finish;
    {
        std::lock_guard<std::mutex> lock(fake_lock);
        ++finish_calls;
        finish_entered = true;
    }
    fake_changed.notify_all();

    require(registered_callback != nullptr,
            "production registration did not retain Callback");
    registered_callback(23, nullptr, nullptr);

    {
        std::unique_lock<std::mutex> lock(fake_lock);
        finish_callback_returned = true;
        fake_changed.notify_all();
        if (should_block)
            fake_changed.wait(lock, [] { return allow_finish; });
    }
    return UPNP_E_SUCCESS;
}

int main()
{
    vlc_object_t object{};
    UpnpInstanceWrapper *first = UpnpInstanceWrapper::get(&object);
    require(first != nullptr && init_calls == 1,
            "initial production get did not create one live instance");

    std::thread releaser([&] { first->release(); });
    wait_for([] { return finish_entered && finish_callback_returned; },
             "Finish callback could not reenter while last release ran");

    std::atomic<bool> getter_started{false};
    std::atomic<bool> getter_finished{false};
    UpnpInstanceWrapper *second = nullptr;
    std::thread getter([&] {
        getter_started = true;
        fake_changed.notify_all();
        second = UpnpInstanceWrapper::get(&object);
        getter_finished = true;
        fake_changed.notify_all();
    });
    wait_for([&] { return getter_started.load(); },
             "concurrent get thread did not start");

    {
        std::unique_lock<std::mutex> lock(fake_lock);
        const bool escaped_teardown = fake_changed.wait_for(
            lock, std::chrono::milliseconds(150),
            [&] { return getter_finished.load() || init_calls.load() > 1; });
        require(!escaped_teardown,
                "concurrent get created an instance before Finish completed");
        allow_finish = true;
    }
    fake_changed.notify_all();

    releaser.join();
    getter.join();
    require(second != nullptr && getter_finished && init_calls == 2,
            "waiting get did not create one new instance after teardown");

    {
        std::lock_guard<std::mutex> lock(fake_lock);
        block_finish = false;
        finish_entered = false;
        finish_callback_returned = false;
        allow_finish = true;
    }
    second->release();
    require(finish_calls == 2 && finish_callback_returned,
            "second final release did not complete through production path");

    std::puts("UPnP lifecycle production probe passed");
    return 0;
}
