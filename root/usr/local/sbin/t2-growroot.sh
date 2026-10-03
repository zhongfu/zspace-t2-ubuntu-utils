#!/bin/sh
# ZSpace T2: grow the root filesystem to the end of its partition, once.
#
# The image is built smaller than p6 (6 GiB artifact, 14 GiB partition) so the
# artifact compresses and flashes fast; the rest of p6 is unusable until this
# runs.  This is what Armbian's / pi-gen's growpart-on-first-boot do, and it
# replaces the vendor `resize-helper`, which resized *every* mounted
# filesystem - including the vendor partitions this image deliberately leaves
# alone.
#
# Safety rules, in order of importance:
#   * only ever touch the partition that / is mounted from;
#   * never resize p7/p8/p9/p10/p11 or anything under /oem, /userdata;
#   * idempotent - a rootfs that already fills its partition is a no-op, and
#     the script disables its own unit once the grow has happened, so it runs
#     on the first boot only (a manual re-run is still harmless).
set -eu

# Test override (mirrors t2-hddled.sh's LEDS_ROOT/BLOCK_ROOT): point this at a
# fake tree to exercise the resolution without a real block device.
SYS=${T2_SYSFS_BLOCK:-/sys/class/block}

log() { echo "t2-growroot: $*"; }

# First boot only: once the grow has happened (or has been proven unnecessary)
# the unit is disabled, so later boots do not even start it.  A resize2fs or
# growpart failure must NOT reach this point - see the exits below - so a
# half-grown rootfs retries on the next boot.  Disabling is file-based
# (systemctl writes the .wants symlink removal); a failure is logged, not
# fatal, because the rootfs is already grown either way.
disable_t2_growroot() {
    if systemctl disable t2-growroot.service >/dev/null 2>&1; then
        log "t2-growroot.service disabled - it runs on the first boot only"
    else
        log "could not disable t2-growroot.service (it will run again next boot)"
    fi
}

src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -z "$src" ]; then
    log "cannot read the source of / - leaving the filesystem alone"
    exit 0
fi
case "$src" in
    /dev/*) ;;
    *)  log "/ is on $src, not a block device - nothing to grow"
        exit 0
        ;;
esac

# Resolve disk/partition from sysfs, NOT from lsblk: `lsblk -no PKNAME/PARTN`
# returns empty when it runs before udev has populated its database, which is
# exactly what happened at first boot (t2-growroot.service: "cannot resolve
# /dev/mmcblk0p6 to a disk/partition pair", measured 2026-09-30, while the same
# lsblk call worked fine later on the running system).  sysfs is always there.
devname=${src##*/}
sysdev=$SYS/$devname
part=$(cat "$sysdev/partition" 2>/dev/null || true)
disk=$(basename "$(readlink -f "$sysdev/..")" 2>/dev/null || true)
log "root filesystem is $src ($devname on ${disk:-?}${part:+ partition $part})"

# Already grown?  resize2fs on a rootfs that already fills its partition is a
# no-op, but it still scans the whole filesystem first: on the board, the
# second boot's resize2fs over the 14 GiB rootfs measured 7.941 s in
# `systemd-analyze blame` (2026-10-01).  Compare the filesystem size against
# the size of the device it lives on and skip both growpart and resize2fs when
# the filesystem is within 2% of it (ext4 metadata means it never equals the
# partition exactly).  Either size being unreadable is not an error: fall
# through to the grow path rather than guess.
part_bytes=$(blockdev --getsize64 "$src" 2>/dev/null || true)
fs_bytes=$(df -B1 --output=size / 2>/dev/null | tail -1 | tr -d ' \n' || true)
case "$fs_bytes" in ''|*[!0-9]*) fs_bytes= ;; esac
case "$part_bytes" in ''|*[!0-9]*) part_bytes= ;; esac
if [ -n "$fs_bytes" ] && [ -n "$part_bytes" ] &&
        [ $((fs_bytes * 100)) -ge $((part_bytes * 98)) ]; then
    log "root filesystem ($fs_bytes B) already fills $src ($part_bytes B) - nothing to grow"
    disable_t2_growroot
    exit 0
fi

if [ -n "$disk" ] && [ -n "$part" ]; then
    if ! growpart "/dev/$disk" "$part" 2>&1; then
        # growpart exits non-zero when there is nothing to grow (p6 is followed
        # by p7, so it is normally already at its maximum); that is success for
        # us as long as the filesystem then fills the partition.
        log "growpart had nothing to do"
    fi
else
    log "no partition number in sysfs - growing the filesystem only"
fi

if ! resize2fs "$src"; then
    log "resize2fs $src failed; the root filesystem stays at its built size"
    exit 1
fi
log "root filesystem now $(df -h --output=size / | tail -1 | tr -d ' ') on $src"

# The grow has succeeded; never do this again.
disable_t2_growroot
