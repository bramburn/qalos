// vendor/aqa/server/src/uinput_injector.hpp
//
// Kernel /dev/uinput touch + key injector for the aqa_server automation daemon.
//
// Pixel 7 Pro (cheetah) target display resolution is 1440x3120 (QHD+).
// The injector creates a virtual multi-touch digitizer that is registered
// with the kernel input subsystem and surfaces as a real touchscreen to
// InputManager and the rest of the framework.

#ifndef AQA_UINPUT_INJECTOR_HPP
#define AQA_UINPUT_INJECTOR_HPP

#include <linux/uinput.h>

namespace aqa {

class UInputInjector {
public:
    UInputInjector();
    ~UInputInjector();

    // Open /dev/uinput and register a virtual touchscreen sized width x height.
    // Returns true on success, false if /dev/uinput cannot be opened or
    // UI_DEV_CREATE fails. The daemon runs as root, so the node's permissions
    // are not normally the blocker — a false return usually means the kernel
    // module is absent or SELinux is enforcing.
    bool init(int width, int height);

    // Inject a single low-level input event.
    void sendEvent(__u16 type, __u16 code, __s32 val);

    // Tap at absolute (x, y). Holds the touch for ~50ms.
    void tap(int x, int y);

    // Swipe from (x1,y1) to (x2,y2) over duration_ms milliseconds at ~60fps.
    void swipe(int x1, int y1, int x2, int y2, int duration_ms);

    // Inject an Android keycode (KEY_* constants).
    void key(int keycode);

private:
    int fd_;
};

}  // namespace aqa

#endif  // AQA_UINPUT_INJECTOR_HPP
