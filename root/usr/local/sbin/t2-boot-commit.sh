#!/bin/sh
# ZSpace T2: commit a boot that reached userspace (the userspace half of the
# kernel A/B fallback).
#
# U-Boot counts boots in its persistent environment (board defconfig
# u-boot/configs/t2-rk3568_defconfig):
#
#   * a freshly written kernel is armed with `upgrade_available=1`,
#     `bootcount=0`;
#   * `bootcount_inc()` -> `bootcount_store()` only *persists* the counter
#     while `upgrade_available != 0` (drivers/bootcount/bootcount_env.c:12-16),
#     so an unarmed board never counts;
#   * once `bootcount > bootlimit` (3), `autoboot.c` runs `altbootcmd`, which
#     sets `t2_fallback=1`, saves the env and boots the previous kernel
#     `/Image.old` instead of `/Image`.
#
# Nothing in the kernel clears that state, so this unit does, once the boot has
# clearly worked (it runs after multi-user.target):
#
#   * `bootcount=0`, `upgrade_available=0` - the kernel that just came up is
#     out of probation, so the counter cannot overflow every 4th boot;
#   * if this boot was the fallback one (`t2_fallback=1`), promote
#     `/Image.old` -> `/Image`: the old kernel proved it boots, so it becomes
#     the new primary and the kernel that failed probation is gone.
#
# The environment is the FAT file `/uboot.env` in p3 (`boot`) - the same file
# U-Boot's `saveenv` writes.  /etc/fw_env.config points libubootenv-tool's
# fw_printenv/fw_setenv at that file through the mount this script makes.
#
# Best-effort by construction: no `boot` partition (a card boot with a
# different layout), no libubootenv, or a read-only card must still boot, so
# every path exits 0 and logs what it could not do.
set -u

# Test overrides (the same style as t2-growroot.sh's T2_SYSFS_BLOCK): point
# these at a fake tree to exercise the logic without a block device.
MNT=${T2_BOOT_MNT:-/run/t2-boot}
DEV=${T2_BOOT_DEV:-}
ENV_CONFIG=${T2_BOOT_FW_ENV_CONFIG:-/etc/fw_env.config}
INITIAL_ENV=${T2_BOOT_INITIAL_ENV:-/etc/u-boot-initial-env}
FW_SETENV=${T2_BOOT_FW_SETENV:-fw_setenv}
FW_PRINTENV=${T2_BOOT_FW_PRINTENV:-fw_printenv}
# CONFIG_ENV_SIZE of the board defconfig (0x1f000): the size of the env *file*,
# CRC header included.  A missing file is created at this size (coreutils'
# truncate wants decimal, not the 0x form).
ENV_SIZE=126976
ENV_FILE=$MNT/uboot.env

log() { echo "t2-boot-commit: $*"; }

# The boot partition is p3 of the disk the root filesystem lives on: U-Boot's
# `CONFIG_ENV_FAT_DEVICE_AND_PART=":3"` resolves to the *boot* device, and for
# every layout this image supports (final eMMC: rootfs p4; card: rootfs p6)
# that is the same disk as /.  Using the root disk also avoids the ambiguity of
# /dev/disk/by-partlabel/boot when the eMMC and the card are both present and
# both carry a partition labelled "boot" (which is exactly the install case).
if [ -z "$DEV" ]; then
    src=$(findmnt -no SOURCE / 2>/dev/null || true)
    case "$src" in
        /dev/*p[0-9]*) DEV=${src%p[0-9]*}p3 ;;
        /dev/*[0-9])   DEV=${src%[0-9]}3 ;;
        *)             DEV=/dev/disk/by-partlabel/boot ;;
    esac
fi

if [ ! -b "$DEV" ]; then
    log "$DEV is not a block device - no U-Boot environment to commit"
    exit 0
fi

mounted=0
if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    if mount -t vfat -o rw "$DEV" "$MNT"; then
        mounted=1
    else
        log "cannot mount $DEV on $MNT - no U-Boot environment to commit"
        exit 0
    fi
fi

cleanup() { [ "$mounted" = 1 ] && umount "$MNT"; }
trap cleanup EXIT

# U-Boot reads the file whole, so it must exist and be exactly ENV_SIZE bytes.
# A missing file is created *blank* (zero-filled) - exactly the state U-Boot's
# own `saveenv` grows out of: U-Boot reports "Cannot read environment, using
# default" and uses its compiled defaults (bootcmd/altbootcmd/bootlimit/
# upgrade_available=0), and the first `saveenv` turns it into a valid blob.
# The libubootenv tools do the same through `-f /etc/u-boot-initial-env`
# (`--defenv`, the compiled default env text this image ships), so from here on
# both readers agree.  Copying that *text* in as the env *file* would not work:
# the file has to be the binary `env_t` blob, CRC32 and all.
if [ ! -e "$ENV_FILE" ]; then
    truncate -s "$ENV_SIZE" "$ENV_FILE" 2>/dev/null && \
        log "created a blank $ENV_SIZE-byte $ENV_FILE"
fi

# value VAR: the var's value, accepting either `VAR=value` or a bare value
# (fw_printenv's output differs between libubootenv versions).
value() {
    raw=$("$FW_PRINTENV" -c "$ENV_CONFIG" -f "$INITIAL_ENV" "$1" 2>/dev/null) || return 1
    case "$raw" in
        "$1="*) printf '%s' "${raw#*=}" ;;
        *)      printf '%s' "$raw" ;;
    esac
}

truthy() { # value
    case "$1" in
        1|y|Y|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

# fw_printenv has to be able to read the env at all; without it (no
# libubootenv, an unreadable file) there is nothing to commit and U-Boot's
# compiled defaults already have bootcount=0 / upgrade_available=0.
if ! value bootcount >/dev/null 2>&1; then
    log "cannot read the U-Boot environment ($ENV_CONFIG / $ENV_FILE) - nothing to commit"
    exit 0
fi

setenv_var() { # VAR VALUE
    # libubootenv-tool 0.3.5 syntax: `fw_setenv [-c config] NAME VALUE` (`-s`
    # is `--script`, it takes no pair - using it silently sets nothing).
    if ! "$FW_SETENV" -c "$ENV_CONFIG" -f "$INITIAL_ENV" "$1" "$2"; then
        log "fw_setenv $1 failed - $ENV_FILE left as it was"
        return 1
    fi
    return 0
}

promoted=0
if truthy "$(value t2_fallback || true)"; then
    if [ -s "$MNT/Image.old" ]; then
        # Copy to a temp name and rename: a reader (U-Boot is not running, but a
        # human with a card reader could be) never sees a half-written /Image.
        cp "$MNT/Image.old" "$MNT/.Image.new" && mv "$MNT/.Image.new" "$MNT/Image" && \
            promoted=1 && log "promoted /Image.old -> /Image (the fallback kernel booted)"
    else
        log "t2_fallback is set but /Image.old is missing - nothing to promote"
    fi
fi

setenv_var bootcount 0 || true
setenv_var upgrade_available 0 || true
if [ "$promoted" = 1 ]; then
    setenv_var t2_fallback 0 || true
    log "committed boot: bootcount=0 upgrade_available=0, promoted the fallback kernel"
else
    log "committed boot: bootcount=0 upgrade_available=0"
fi
exit 0
