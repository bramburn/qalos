---
id: agent-developer-guide
title: Agent developer guide
sidebar_label: Agent dev guide
sidebar_position: 7
description: How to write an LLM agent that drives a phone running QA Lab OS.
---

# Agent developer guide

This guide is for the developer of the **agent** — the LLM-driven
loop on the workstation that observes the screen, decides the next
action, and calls the API.

## Philosophy

The phone is a **dumb execution endpoint**. It sees, it taps, it
types. The agent is the **brain**. It makes all decisions.

The agent does not have access to the accessibility tree, the XML
view hierarchy, or any element IDs. It has screenshots and pixel
coordinates. This is a feature, not a limitation:

- **Resilient to UI refactors.** No element library to maintain.
- **Universal.** Works on any app, including WebViews, games, and
  third-party apps that do not expose accessibility metadata.
- **LLM-native.** GPT-4o, Claude 3.5 Sonnet, and similar models
  can read a screenshot and output `(x, y)` coordinates naturally.

## Coordinate system

- **Origin** is the top-left corner of the screen.
- **`x`** is the horizontal pixel position, in `[0, width-1]`.
- **`y`** is the vertical pixel position, in `[0, height-1]`.
- Use `GET /display` once at the start of a session to learn the
  screen size. The Pixel 7 emulator reports `1080 x 2400`; physical
  devices may differ.

## The recommended loop

```python
import time
from qa_lab_os import QaLabDevice


def agent_loop(device: QaLabDevice, goal: str, max_steps: int = 20) -> bool:
    """Run the agent loop. Returns True if the goal was met."""
    history: list[dict] = []
    for step in range(max_steps):
        # 1. Observe
        screenshot = device.screenshot()

        # 2. Think
        action = llm_decide(screenshot, goal, history)
        # action is one of:
        #   {"action": "tap",     "x": 540, "y": 1200}
        #   {"action": "type",    "text": "hello"}
        #   {"action": "key",     "key_code": 4, "down": true}
        #   {"action": "launch",  "package": "com.example.app"}
        #   {"action": "force_stop", "package": "com.example.app"}
        #   {"action": "done"}

        history.append(action)

        # 3. Act
        if action["action"] == "done":
            return True
        if action["action"] == "tap":
            device.tap(action["x"], action["y"])
        elif action["action"] == "type":
            device.type_text(action["text"])
        elif action["action"] == "key":
            device.key(action["key_code"], down=action.get("down", True))
        elif action["action"] == "launch":
            device.launch(action["package"])
        elif action["action"] == "force_stop":
            device.force_stop(action["package"])

        # 4. Wait for the UI to settle. 500 ms is a good default;
        #    shorter for snappy UIs (a list scroll is fine at
        #    200 ms), longer for animated transitions (a screen
        #    push is safer at 800 ms). The cost of a too-low value
        #    is a blurry screenshot that confuses the LLM.
        time.sleep(0.5)

    return False
```

## The recommended system prompt

```text
You control an Android phone by looking at screenshots and sending
tap / type / key / launch / force_stop commands.

Rules:
- Respond with ONE action per turn, in this exact JSON format:
    {"action": "tap",        "x": 540, "y": 1200}
    {"action": "type",       "text": "hello"}
    {"action": "key",        "key_code": 4, "down": true}
    {"action": "launch",     "package": "com.example.app"}
    {"action": "force_stop", "package": "com.example.app"}
    {"action": "done"}
- Coordinates must be within the screen bounds (you can call
  `display_size` if you do not know them).
- If you do not know where to tap, do not guess; ask for a fresh
  screenshot or a partial screenshot of the region you are
  reasoning about.
- After tapping, wait for the UI to settle (≈500 ms) before the
  next screenshot.
- Use `key_code: 4` for BACK and `key_code: 3` for HOME.
- Prefer `type` over per-character key events for text input.
```

## Latency budget

| Operation | Expected latency |
| --- | --- |
| `/health` | < 10 ms |
| `/display` | < 20 ms |
| `/foreground` | < 20 ms |
| `/tap`, `/key`, `/type` | 20-50 ms |
| `/launch`, `/force_stop` | 100 ms - 2 s (depends on the app) |
| `/screenshot` (native) | 100-200 ms |
| `/screenshot` (downscaled, 480x800) | 50-100 ms |

Plan for ~700 ms per decision cycle (screenshot + LLM + action +
settle). A 20-step agent loop is ≈14 s.

## Down-scaling screenshots

Sending the full 1080x2400 PNG to the LLM every step is expensive.
Use the `width` and `height` query parameters on `/screenshot` to
down-scale:

```python
screenshot = device.screenshot(width=540, height=1200, quality=75)
```

A good rule of thumb:

- For **text-heavy** screens (settings, lists, dialogs), prefer
  the native resolution so the LLM can read the text.
- For **graphical** screens (camera viewfinder, video, games),
  down-scale to 540x1200 to save bandwidth.
- Always pass `quality < 90` for LLM use; the loss is invisible to
  vision models and the payload halves.

## Common pitfalls

- **Animations.** A screenshot taken 50 ms after a tap can catch a
  transition mid-frame. Wait 300-500 ms after every tap.

- **Soft keyboards.** After `type`, the keyboard covers the bottom
  half of the screen. The screenshot will look very different
  from the pre-tap state. Send `key_code: 4` (BACK) to dismiss
  the keyboard if the next step needs the underlying UI.

- **Relative vs absolute coordinates.** Some LLMs reason in
  percentages (`0.0` to `1.0`). Convert before calling the API:

  ```python
  w, h = device.display_size.as_tuple()
  device.tap(int(rx * w), int(ry * h))
  ```

  The Python client has a `tap_relative` helper for this.

- **OCR hallucinations.** Small text (under ~20 px tall) is hard
  for vision models. Zoom in by taking a sub-screenshot if you
  need to read small text (a future API will support this; in v0,
  down-scaling the display is the workaround).

- **Context menus.** A `long_press` opens a context menu; a `tap`
  selects. The v0 API has no `long_press`; use `key` with a menu
  keycode or chain a tap + a delayed second tap as a workaround.

- **App not in foreground.** If `device.foreground_package` returns
  `""` or an unexpected package, the agent should `launch` the
  target app before continuing.

## Multi-device

The Python client is thread-safe. To drive two devices
simultaneously:

```python
from qa_lab_os import QaLabDevice
import threading

def driver_flow(d: QaLabDevice) -> None:
    d.launch("com.delivery.driver")
    # ...

def customer_flow(d: QaLabDevice) -> None:
    d.launch("com.delivery.customer")
    # ...

with QaLabDevice("phone-a", 9000) as phone_a, \
     QaLabDevice("phone-b", 9000) as phone_b:
    t1 = threading.Thread(target=driver_flow, args=(phone_a,))
    t2 = threading.Thread(target=customer_flow, args=(phone_b,))
    t1.start(); t2.start()
    t1.join(); t2.join()
```

Each device needs its own `adb forward`. For two emulators:

```bash
adb -s emulator-5554 forward tcp:9000 tcp:9000
adb -s emulator-5556 forward tcp:9001 tcp:9000
```

Then connect with `QaLabDevice("localhost", 9000)` and
`QaLabDevice("localhost", 9001)`.

## Reference

- [API reference](./api) — every endpoint, every error code
- [Architecture](./architecture) — what runs where
- [Build guide](./build-guide) — how to build, flash, verify
