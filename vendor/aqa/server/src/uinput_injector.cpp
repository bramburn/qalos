// vendor/aqa/server/src/uinput_injector.cpp
//
// See uinput_injector.hpp for design notes.

#include "uinput_injector.hpp"

#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <linux/uinput.h>
#include <sys/ioctl.h>

namespace aqa {
namespace {

// ioctl()/write() on a uinput fd can legitimately fail (device busy, no
// permission on one axis, ENODEV after a hot-unplug). They are best-effort
// and the return value is deliberately not propagated.
void bestEffort(int rc) { static_cast<void>(rc); }

}  // namespace

UInputInjector::UInputInjector() : fd_(-1) {}

UInputInjector::~UInputInjector() {
    if (fd_ >= 0) {
        bestEffort(ioctl(fd_, UI_DEV_DESTROY));
        close(fd_);
        fd_ = -1;
    }
}

bool UInputInjector::init(int width, int height) {
    fd_ = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd_ < 0) return false;

    bestEffort(ioctl(fd_, UI_SET_EVBIT, EV_ABS));
    bestEffort(ioctl(fd_, UI_SET_EVBIT, EV_KEY));
    bestEffort(ioctl(fd_, UI_SET_EVBIT, EV_SYN));

    bestEffort(ioctl(fd_, UI_SET_KEYBIT, BTN_TOUCH));
    bestEffort(ioctl(fd_, UI_SET_KEYBIT, KEY_POWER));
    bestEffort(ioctl(fd_, UI_SET_KEYBIT, KEY_HOMEPAGE));
    bestEffort(ioctl(fd_, UI_SET_KEYBIT, KEY_BACK));

    bestEffort(ioctl(fd_, UI_SET_ABSBIT, ABS_X));
    bestEffort(ioctl(fd_, UI_SET_ABSBIT, ABS_Y));
    bestEffort(ioctl(fd_, UI_SET_ABSBIT, ABS_MT_POSITION_X));
    bestEffort(ioctl(fd_, UI_SET_ABSBIT, ABS_MT_POSITION_Y));
    bestEffort(ioctl(fd_, UI_SET_ABSBIT, ABS_MT_TRACKING_ID));

    struct uinput_user_dev uidev;
    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "aqa-virtual-touchscreen");
    uidev.id.bustype = BUS_VIRTUAL;
    uidev.id.vendor  = 0x18d1;  // Google
    uidev.id.product = 0x0001;

    uidev.absmin[ABS_X] = 0;
    uidev.absmax[ABS_X] = width;
    uidev.absmin[ABS_Y] = 0;
    uidev.absmax[ABS_Y] = height;

    uidev.absmin[ABS_MT_POSITION_X] = 0;
    uidev.absmax[ABS_MT_POSITION_X] = width;
    uidev.absmin[ABS_MT_POSITION_Y] = 0;
    uidev.absmax[ABS_MT_POSITION_Y] = height;
    uidev.absmin[ABS_MT_TRACKING_ID] = 0;
    uidev.absmax[ABS_MT_TRACKING_ID] = 65535;

    ssize_t written = write(fd_, &uidev, sizeof(uidev));
    if (written < 0 || static_cast<size_t>(written) != sizeof(uidev)) {
        close(fd_);
        fd_ = -1;
        return false;
    }
    return ioctl(fd_, UI_DEV_CREATE) >= 0;
}

void UInputInjector::sendEvent(__u16 type, __u16 code, __s32 val) {
    if (fd_ < 0) return;
    struct input_event ie;
    memset(&ie, 0, sizeof(ie));
    ie.type = type;
    ie.code = code;
    ie.value = val;
    bestEffort(static_cast<int>(write(fd_, &ie, sizeof(ie))));
}

void UInputInjector::tap(int x, int y) {
    sendEvent(EV_ABS, ABS_MT_TRACKING_ID, 1);
    sendEvent(EV_KEY, BTN_TOUCH, 1);
    sendEvent(EV_ABS, ABS_MT_POSITION_X, x);
    sendEvent(EV_ABS, ABS_MT_POSITION_Y, y);
    sendEvent(EV_SYN, SYN_REPORT, 0);

    usleep(50000);  // 50ms hold

    sendEvent(EV_ABS, ABS_MT_TRACKING_ID, -1);
    sendEvent(EV_KEY, BTN_TOUCH, 0);
    sendEvent(EV_SYN, SYN_REPORT, 0);
}

void UInputInjector::swipe(int x1, int y1, int x2, int y2, int duration_ms) {
    if (duration_ms < 0) duration_ms = 0;
    int steps = duration_ms / 16;  // ~60fps
    if (steps < 1) steps = 1;

    sendEvent(EV_ABS, ABS_MT_TRACKING_ID, 1);
    sendEvent(EV_KEY, BTN_TOUCH, 1);
    sendEvent(EV_ABS, ABS_MT_POSITION_X, x1);
    sendEvent(EV_ABS, ABS_MT_POSITION_Y, y1);
    sendEvent(EV_SYN, SYN_REPORT, 0);

    for (int i = 1; i <= steps; ++i) {
        usleep(16000);
        int cur_x = x1 + ((x2 - x1) * i) / steps;
        int cur_y = y1 + ((y2 - y1) * i) / steps;
        sendEvent(EV_ABS, ABS_MT_POSITION_X, cur_x);
        sendEvent(EV_ABS, ABS_MT_POSITION_Y, cur_y);
        sendEvent(EV_SYN, SYN_REPORT, 0);
    }

    sendEvent(EV_ABS, ABS_MT_TRACKING_ID, -1);
    sendEvent(EV_KEY, BTN_TOUCH, 0);
    sendEvent(EV_SYN, SYN_REPORT, 0);
}

void UInputInjector::key(int keycode) {
    sendEvent(EV_KEY, keycode, 1);
    sendEvent(EV_SYN, SYN_REPORT, 0);
    usleep(30000);  // 30ms hold
    sendEvent(EV_KEY, keycode, 0);
    sendEvent(EV_SYN, SYN_REPORT, 0);
}

}  // namespace aqa