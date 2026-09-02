#ifndef SWIFTVLC_UPNP_FAKE_CXX_HELPERS_HPP
#define SWIFTVLC_UPNP_FAKE_CXX_HELPERS_HPP

#include <condition_variable>
#include <mutex>

namespace vlc {
namespace threads {

class condition_variable;
class mutex_locker;

class mutex
{
public:
    void lock() { value.lock(); }
    void unlock() { value.unlock(); }

private:
    std::mutex value;
    friend class condition_variable;
    friend class mutex_locker;
};

class condition_variable
{
public:
    void signal() { value.notify_one(); }
    void broadcast() { value.notify_all(); }

    void wait(mutex &guard)
    {
        std::unique_lock<std::mutex> held(guard.value, std::adopt_lock);
        value.wait(held);
        held.release();
    }

private:
    std::condition_variable value;
};

class mutex_locker
{
public:
    explicit mutex_locker(mutex &guard) : guard(guard) { guard.lock(); }
    ~mutex_locker() { guard.unlock(); }

    mutex_locker(const mutex_locker &) = delete;
    mutex_locker &operator=(const mutex_locker &) = delete;

private:
    mutex &guard;
};

} // namespace threads
} // namespace vlc

#endif
