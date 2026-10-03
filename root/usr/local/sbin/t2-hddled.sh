#!/bin/sh
# t2-hddled: per-bay drive LEDs on the ZSpace T2.
#
# Adapted from the Q2C fnOS board patch (`q2c-hddled.py`, recovered from
# q2c_fnOS_1.2.0302.img.xz).  Kernel LED triggers cannot express per-bay or
# fault semantics: the running kernel offers
# `disk-activity`/`disk-read`/`disk-write` (global: any block device) and
# `mmc0`/`mmc1` (per MMC controller), but mainline 7.3 has no per-block-device
# trigger (`ledtrig-blkdev` is not in drivers/leds/trigger/).  So this is
# genuine userspace policy, and it is the *only* writer for the four hdd* LEDs
# (fnOS shipped two owners fighting over the same entries - do not repeat it).
#
# Semantics, adapted to the T2's hardware:
#   * green: solid while the bay has a block device, toggling while that device
#     is doing I/O (blink = activity); off when the bay is empty.
#   * red:   solid when the bay is a member of a degraded/faulty md array.
#   * The T2's bays are M.2 NVMe.  NVMe has APST power states and no sysfs
#     "standby" indicator (unlike ATA `hdparm -C`), so the Q2C's standby
#     handling is deliberately not implemented; neither is the SMART
#     self-test check (nvme-cli's smart-log is too heavy for a 1 s loop -
#     it belongs on its own slower timer).
#
# Configuration: /etc/default/t2-hddled
#   MAP="hdd1=nvme0n1 hdd2=nvme1n1"   bay -> /sys/block device
#   POLL=1                            poll interval, seconds
#
# Test/override env: LEDS_ROOT, BLOCK_ROOT, T2_HDDLED_CONF, MAX_ITERATIONS.
# Host test (no board needed): scripts/tests/test-t2-hddled.sh
set -u

CONF=${T2_HDDLED_CONF:-/etc/default/t2-hddled}
LEDS_ROOT=${LEDS_ROOT:-/sys/class/leds}
BLOCK_ROOT=${BLOCK_ROOT:-/sys/block}
MAX_ITERATIONS=${MAX_ITERATIONS:-0}

MAP="hdd1=nvme0n1 hdd2=nvme1n1"
POLL=1
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

led_set() {
    # $1 = LED name, $2 = 0/1
    dir="$LEDS_ROOT/$1"
    [ -d "$dir" ] || return 0
    # Exactly one owner: never let a kernel trigger drive these.
    echo none > "$dir/trigger" 2>/dev/null || true
    echo "$2" > "$dir/brightness" 2>/dev/null || true
}

led_get() {
    cat "$LEDS_ROOT/$1/brightness" 2>/dev/null || echo 0
}

sectors() {
    # $1 = block device; prints sectors read + written, fails if absent.
    [ -r "$BLOCK_ROOT/$1/stat" ] || return 1
    # fields: reads completed, reads merged, sectors read, ms reading,
    #         writes completed, writes merged, sectors written, ...
    set -- $(cat "$BLOCK_ROOT/$1/stat")
    echo $(( $3 + $7 ))
}

bay_fault() {
    # $1 = block device; 0 if one of its partitions is a sick md member, or if
    # it is a member of an array that is degraded (a degraded *other* bay's
    # array must not light this bay's red LED).
    dev=$1
    for st in $BLOCK_ROOT/md*/md/dev-$dev*/state; do
        [ -r "$st" ] || continue
        case "$(cat "$st")" in
            *faulty*|*write_error*|*blocked*|*removed*) return 0 ;;
        esac
    done
    for md in $BLOCK_ROOT/md*/md; do
        [ -d "$md" ] || continue
        [ -r "$md/degraded" ] || continue
        # membership: an md/dev-<dev> (or md/dev-<dev>NN) entry exists
        set -- "$md"/dev-"$dev"*
        [ -e "$1" ] || continue
        [ "$(cat "$md/degraded")" != 0 ] && return 0
    done
    return 1
}

i=0
while :; do
    for pair in $MAP; do
        bay=${pair%%=*}
        dev=${pair#*=}

        cur=$(sectors "$dev" 2>/dev/null) || cur=""

        if [ -z "$cur" ]; then
            # bay empty (or device gone)
            led_set "${bay}-led-green" 0
            led_set "${bay}-led-red" 0
            eval "prev_${bay}="
            continue
        fi

        if bay_fault "$dev"; then
            led_set "${bay}-led-red" 1
        else
            led_set "${bay}-led-red" 0
        fi

        eval "prev=\${prev_${bay}:-}"
        if [ -n "$prev" ] && [ "$cur" != "$prev" ]; then
            # activity: blink
            if [ "$(led_get "${bay}-led-green")" = 1 ]; then
                led_set "${bay}-led-green" 0
            else
                led_set "${bay}-led-green" 1
            fi
        else
            led_set "${bay}-led-green" 1
        fi
        eval "prev_${bay}=\$cur"
    done

    i=$((i + 1))
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$i" -ge "$MAX_ITERATIONS" ]; then
        break
    fi
    sleep "$POLL"
done
