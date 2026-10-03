#!/bin/sh
# ZSpace T2 LED policy: the *power* LEDs only.
#
# The four hdd* LEDs are owned by t2-hddled (per-bay present/activity/fault) -
# this script must not touch them, or the two owners fight over the same
# /sys/class/leds entries (exactly the bug the Q2C fnOS board patch works
# around).
#
# Vendor semantics: power green = steady on, power red = fault indication.
# A real fault policy needs userspace knowledge of the system state, which
# this base image deliberately does not have, so red stays off.
set -u

set_trigger() {
    dir="/sys/class/leds/$1"
    [ -d "$dir" ] || return 0
    echo "$2" > "$dir/trigger" 2>/dev/null || true
}

set_brightness() {
    dir="/sys/class/leds/$1"
    [ -d "$dir" ] || return 0
    echo "$2" > "$dir/brightness" 2>/dev/null || true
}

set_trigger power-led-green none
set_brightness power-led-green 1

set_trigger power-led-red none
set_brightness power-led-red 0
