#!/usr/bin/env python3
"""ZSpace T2 power-button policy (t2-powerkey.service).

Policy: a *short* press of the power button is a no-op; a press held for
`press_seconds` (default 3 s) asks systemd for a graceful poweroff.  The
decision happens *while the button is still down* - the moment the hold
reaches the threshold - because requiring a release is exactly the annoyance
this daemon removes.  A much longer hold never reaches the threshold path:
the RK809 PMIC cuts the rails itself (the PMIC's own long-press timeout),
which is the last-resort power cut, so `press_seconds` must stay well below
it (see /etc/t2/powerkey.conf).

Indicator (kept in this daemon; t2-leds.sh owns the steady green and must not
be touched): the red power LED turns on as soon as the button goes down
(progress feedback), turns off again after a short press, and blinks at
`blink_seconds` (default 0.25 s, 2 Hz) from the instant poweroff is initiated
until this process is torn down by the shutdown.

Why userspace: the PMIC's PWRON input device (rk805-pwrkey) reports only
press/release - it has no notion of press duration - and systemd-logind's
HandlePowerKey=poweroff would turn *every* touch into a poweroff.  The
logind drop-in /etc/systemd/logind.conf.d/10-t2.conf gives the key to this
service instead (HandlePowerKey=ignore).

Config: /etc/t2/powerkey.conf (device name as reported by EVIOCGNAME, key
code, press_seconds, LED root/name/blink).  An empty `device=` falls back to
the first input device that can emit `code`, mirroring the initramfs press
gate.

Test hooks (host-side tests only): T2_POWERKEY_CONF overrides the config
path, T2_POWERKEY_INPUT_DIR the /dev/input directory, T2_POWERKEY_SYSTEMCTL
the systemctl binary, T2_POWERKEY_LEDS the LED class root.  `--simulate`
reads "<press> [<release>]" seconds from stdin and prints the decision and
the indicator transitions for each instead of touching any device (implies
--dry-run); a bare "<press>" means the key is never released and must still
power off at the threshold.
"""

import fcntl
import glob
import os
import select
import struct
import subprocess
import sys
import time

EV_KEY = 1
KEY_POWER = 116
INPUT_EVENT = struct.Struct("llHHi")  # struct input_event, LP64: 24 bytes
KEY_BITMAP_BYTES = 96  # KEY_MAX is 0x2ff

DEF_CONF = "/etc/t2/powerkey.conf"
INPUT_DIR = os.environ.get("T2_POWERKEY_INPUT_DIR", "/dev/input")
DEFAULTS = {
    "device": "rk805 pwrkey",
    "code": str(KEY_POWER),
    "press_seconds": "3",
    "leds_dir": "/sys/class/leds",
    "led": "power-led-red",
    "blink_seconds": "0.25",
}


def _ioc(direction, kind, nr, size):
    return (direction << 30) | (size << 16) | (kind << 8) | nr


def eviocgname(length):
    return _ioc(2, ord("E"), 0x06, length)  # _IOR('E', 0x06, char[length])


def eviocgbit(ev, length):
    return _ioc(2, ord("E"), 0x20 + ev, length)


def log(message):
    print("t2-powerkey: %s" % message, flush=True)


def read_conf(path):
    cfg = dict(DEFAULTS)
    try:
        with open(path) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if not line or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                cfg[key.strip()] = value.strip()
    except FileNotFoundError:
        log("no config at %s, using defaults" % path)
    return cfg


def device_name(fd):
    buf = fcntl.ioctl(fd, eviocgname(256), b"\0" * 256)
    return buf.split(b"\0", 1)[0].decode("utf-8", "replace")


def device_has_key(fd, code):
    bits = fcntl.ioctl(fd, eviocgbit(EV_KEY, KEY_BITMAP_BYTES),
                       b"\0" * KEY_BITMAP_BYTES)
    return bool(bits[code // 8] >> (code % 8) & 1)


def open_device(want, code):
    """Open the matching event device, or None."""
    for path in sorted(glob.glob(os.path.join(INPUT_DIR, "event*"))):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            name = device_name(fd)
            if want:
                if name == want:
                    return fd, path, name
            elif device_has_key(fd, code):
                return fd, path, name
        except OSError:
            pass
        os.close(fd)
    return None


class Led:
    """One entry under the LED class root; t2-leds.sh owns the green one."""

    def __init__(self, path):
        self.path = path
        self.value = None

    def set(self, on):
        want = 1 if on else 0
        try:
            with open(self.path, "w") as fh:
                fh.write("%d" % want)
        except OSError:
            return
        self.value = want


class PressState:
    """Press-duration policy, independent of evdev/IO so it is unit-testable.

    feed(value, now) applies one EV_KEY edge (1 press, 0 release) and returns
    its meaning: 'press', 'release-ignore', 'poweroff' (a release that already
    crossed the threshold) or None.  due(now) fires exactly once, while the
    key is still down, the moment the hold reaches `press_seconds` - the
    threshold path must never wait for a release.
    """

    def __init__(self, press_seconds):
        self.press_seconds = press_seconds
        self.pressed_at = None
        self.powered_off = False

    def feed(self, value, now):
        if self.powered_off:
            return None
        if value == 1:
            self.pressed_at = now
            return "press"
        if value == 0:
            if self.pressed_at is None:
                return None
            held = now - self.pressed_at
            self.pressed_at = None
            if held >= self.press_seconds:
                self.powered_off = True
                return "poweroff"
            return "release-ignore"
        return None

    def due(self, now):
        if (not self.powered_off and self.pressed_at is not None
                and now - self.pressed_at >= self.press_seconds):
            self.powered_off = True
            return True
        return False


def issue_poweroff(systemctl, dry_run):
    """Ask systemd to power off; return its exit status (0 = accepted).

    A refusal (shutdown inhibitor, missing binary) must not brick the button
    for the rest of the session, so the caller re-arms the press policy when
    this does not return 0.
    """
    if dry_run:
        log("dry-run: would run %s poweroff" % systemctl)
        return 0
    try:
        rc = subprocess.call([systemctl, "poweroff"])
        log("systemctl poweroff -> rc %d" % rc)
        return rc
    except OSError as exc:
        log("cannot run %s poweroff: %s" % (systemctl, exc))
        return 127


def simulate(press_seconds, blink_seconds, stream):
    """Replay '<press> [<release>]' seconds; no device or LED is touched."""
    for lineno, line in enumerate(stream, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) not in (1, 2):
            log("simulate: line %d: expected '<press> [<release>]'" % lineno)
            return 2
        try:
            press = float(fields[0])
            release = float(fields[1]) if len(fields) == 2 else None
        except ValueError:
            log("simulate: line %d: expected numbers" % lineno)
            return 2
        if release is not None and release < press:
            log("simulate: line %d: release before press" % lineno)
            return 2
        state = PressState(press_seconds)
        fire_at = press + press_seconds
        state.feed(1, press)
        log("t=%.3f button down -> red on" % press)
        if release is None or release >= fire_at:
            # threshold reached while the key is still down
            state.due(fire_at)
            log("t=%.3f held %.3f s -> poweroff (button still down), "
                "red blink %.2f s" % (fire_at, press_seconds, blink_seconds))
            if release is not None:
                log("t=%.3f release after poweroff -> ignored" % release)
        else:
            state.feed(0, release)
            log("t=%.3f held %.3f s -> ignored (short press), red off"
                % (release, release - press))
    return 0


def run_live(want, code, press_seconds, blink_seconds, led_path, systemctl,
             dry_run):
    logged_missing = False
    while True:
        opened = open_device(want, code)
        if opened is None:
            if not logged_missing:
                log("waiting for %s" % (want or "a device reporting code %d" % code))
                logged_missing = True
            time.sleep(2)
            continue
        fd, path, name = opened
        log("watching %s (%s), press >= %.1f s powers off"
            % (name, path, press_seconds))
        logged_missing = False
        led = Led(led_path)
        state = PressState(press_seconds)
        blink_at = None
        led.set(False)
        try:
            while True:
                now = time.monotonic()
                timeout = None
                if state.powered_off:
                    timeout = max(0.0, blink_seconds - (now - blink_at))
                elif state.pressed_at is not None:
                    timeout = max(0.0, press_seconds - (now - state.pressed_at))
                ready = select.select([fd], [], [], timeout)[0]
                now = time.monotonic()
                if ready:
                    data = os.read(fd, INPUT_EVENT.size * 64)
                    if not data:
                        raise OSError("device closed")
                    for off in range(0, len(data) - INPUT_EVENT.size + 1,
                                    INPUT_EVENT.size):
                        _, _, etype, ecode, value = INPUT_EVENT.unpack_from(data, off)
                        if etype != EV_KEY or ecode != code:
                            continue
                        was_pressed = state.pressed_at
                        action = state.feed(value, now)
                        if action == "press":
                            led.set(True)
                            log("button down -> red on")
                        elif action == "release-ignore":
                            led.set(False)
                            log("held %.1f s -> ignored (short press), red off"
                                % (now - was_pressed))
                        elif action == "poweroff":
                            log("held %.1f s -> poweroff (released past the "
                                "threshold)" % (now - was_pressed))
                            led.set(True)
                            if issue_poweroff(systemctl, dry_run) == 0:
                                blink_at = now + blink_seconds
                            else:
                                # refused: re-arm so a fresh hold can retry
                                state.powered_off = False
                                led.set(False)
                if state.due(now):
                    log("held %.1f s -> poweroff (threshold reached, button "
                        "still down)" % (now - state.pressed_at))
                    led.set(True)
                    if issue_poweroff(systemctl, dry_run) == 0:
                        blink_at = now + blink_seconds
                    else:
                        # refused: re-arm so a fresh hold can retry
                        state.powered_off = False
                        state.pressed_at = None
                        led.set(False)
                if state.powered_off and now >= blink_at:
                    led.set(not led.value)
                    blink_at = now + blink_seconds
        except OSError as exc:
            log("%s: %s - rescanning" % (path, exc))
            os.close(fd)
            time.sleep(2)


def main(argv):
    dry_run = "--dry-run" in argv
    simulate_mode = "--simulate" in argv
    cfg = read_conf(os.environ.get("T2_POWERKEY_CONF", DEF_CONF))
    try:
        code = int(cfg["code"], 0)
        press_seconds = float(cfg["press_seconds"])
        blink_seconds = float(cfg["blink_seconds"])
    except ValueError as exc:
        log("bad config: %s" % exc)
        return 2
    if press_seconds <= 0 or blink_seconds <= 0:
        log("bad config: press_seconds and blink_seconds must be > 0")
        return 2
    leds_dir = os.environ.get("T2_POWERKEY_LEDS", cfg["leds_dir"])
    led_path = os.path.join(leds_dir, cfg["led"], "brightness")
    if simulate_mode:
        return simulate(press_seconds, blink_seconds, sys.stdin)
    run_live(cfg["device"], code, press_seconds, blink_seconds, led_path,
             os.environ.get("T2_POWERKEY_SYSTEMCTL", "/usr/bin/systemctl"),
             dry_run)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
