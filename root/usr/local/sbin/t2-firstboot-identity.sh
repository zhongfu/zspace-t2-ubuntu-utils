#!/bin/sh
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# ZSpace T2: establish the per-board identity on the *first* boot.
#
# The shipped image is identical on every board by construction: the build
# truncates /etc/machine-id to 0 bytes (hooks/20-basics.sh) and the root
# filesystem keeps the single UUID `mke2fs` produced.  This script replaces
# both with per-board values, once:
#
#   * machine-id - systemd(1) generates a transient ID for an empty
#     /etc/machine-id during early boot, and systemd-machine-id-commit.service
#     (shipped by systemd 259.5 on Ubuntu 26.04 and statically enabled under
#     /usr/lib/systemd/system/sysinit.target.wants/) writes it to disk.  If
#     that did not happen - older systemd, or a failed commit - generate and
#     commit one here.  The whole block is guarded on /etc/machine-id still
#     being empty, so it is a no-op whenever systemd already did its job.
#
#   * root filesystem UUID - `tune2fs -U random` makes the root fs unique per
#     board.  Nothing resolves root by fs UUID (checked 2026-10-02): the
#     FIT's chosen/bootargs and the card's extlinux.conf both use
#     `root=LABEL=zspace-rootfs`, /etc/fstab (hooks/20-basics.sh) uses
#     PARTUUID, and every runtime mount helper (t2-provision.sh,
#     t2-usbgadget.sh) resolves by LABEL/PARTLABEL.
#     The only consumer of the image.json `fs_uuid` is the build-time
#     `mke2fs -U` in scripts/t2-distro.py.  So regenerating it only removes a
#     fleet-wide identifier.
#
#   * hostname - the baked default is `t2` (hooks/20-basics.sh); make it
#     `t2-<last 6 hex of the machine-id>` so two flashed boards differ.  It is
#     only replaced while the hostname is still that baked default, so a
#     `hostname=` key applied by t2-provision.service - which runs *after*
#     this unit - is never clobbered on a later boot.
#
# Idempotent: a stamp file records that the identity is established, so the
# unit is a no-op from the second boot on.  If the fs UUID step failed or there
# was no tune2fs, the stamp is withheld and only that step is retried - the
# machine-id and hostname blocks guard themselves, so re-running can never
# regenerate the ID or overwrite a provisioned hostname.
#
# Best-effort throughout (set -u, deliberately no set -e): a missing tune2fs or
# an unreadable root device logs and exits 0 rather than failing the boot.
set -u

# Test override (same pattern as t2-provision.sh's T2_PROVISION_ROOT): relocate
# every path this script reads/writes.
ROOT=${T2_FIRSTBOOT_ROOT:-/}
STAMP="$ROOT/var/lib/t2-firstboot/identity"
LOG="$ROOT/var/log/t2-firstboot.log"
# The baked default, as written by hooks/20-basics.sh.  Anything else is
# either a previous boot's derived name or a provisioned one - never touch it.
DEFAULT_HOSTNAME=t2

log() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
	echo "$(date -Is) t2-firstboot: $*" >>"$LOG" 2>/dev/null || true
	echo "t2-firstboot: $*"
}

if [ -f "$STAMP" ]; then
	log "identity already established; nothing to do"
	exit 0
fi

# --- machine-id -------------------------------------------------------------
# systemd commits the transient ID itself; only fill the file in if it is
# still empty when this unit runs.
machine_id=$(cat "$ROOT/etc/machine-id" 2>/dev/null || true)
if [ -z "$machine_id" ]; then
	log "/etc/machine-id is empty; committing a machine-id"
	# --commit is a no-op unless /etc/machine-id is a tmpfs mount, so a plain
	# invocation (which generates a fresh random ID for an empty file) is the
	# fallback when this does not populate the file.
	systemd-machine-id-setup --commit >/dev/null 2>&1 || true
	if [ ! -s "$ROOT/etc/machine-id" ]; then
		systemd-machine-id-setup >/dev/null 2>&1 || true
	fi
	machine_id=$(cat "$ROOT/etc/machine-id" 2>/dev/null || true)
fi

# --- root filesystem UUID ---------------------------------------------------
# Only ever touch the filesystem / is mounted from.  A board whose root fs UUID
# is not settled retries on the next boot rather than being stamped as done.
uuid_settled=yes
src=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -z "$src" ]; then
	log "cannot read the source of /; fs UUID left alone"
	uuid_settled=no
else
	case "$src" in
	/dev/*)
		if command -v tune2fs >/dev/null 2>&1; then
			if tune2fs -U random "$src" >/dev/null 2>&1; then
				log "root filesystem UUID regenerated on $src"
			else
				log "tune2fs -U random $src failed; retrying next boot"
				uuid_settled=no
			fi
		else
			log "no tune2fs; fs UUID left alone (retrying next boot)"
			uuid_settled=no
		fi
		;;
	*)
		log "/ is on $src, not a block device; fs UUID left alone"
		;;
	esac
fi

# --- hostname ---------------------------------------------------------------
# Derive the per-board name from the last 6 hex characters of the machine-id.
name=
if [ -n "$machine_id" ] && [ "${#machine_id}" -ge 6 ]; then
	name="t2-${machine_id#"${machine_id%??????}"}"
fi
current=$(cat "$ROOT/etc/hostname" 2>/dev/null | tr -d '\n' || true)
if [ -z "$name" ]; then
	log "no usable machine-id; hostname left as '$current'"
elif [ "$current" != "$DEFAULT_HOSTNAME" ]; then
	log "hostname already '$current'; not overriding with $name"
elif "$SELF/t2-sethostname" --root "$ROOT" "$name"; then
	# the helper also rewrites the 127.0.1.1 line in /etc/hosts, which would
	# otherwise still map the baked default `t2`; hostnamed does not run this
	# early, so the running name is set with hostname(1)
	hostname "$name" >/dev/null 2>&1 || true
	log "hostname -> $name"
else
	log "could not write $ROOT/etc/hostname; hostname left as '$current'"
fi

# --- stamp ------------------------------------------------------------------
# The stamp is only written once the fs UUID is settled; a failed/skipped
# tune2fs leaves the unit to retry on the next boot.  The machine-id and
# hostname blocks guard themselves, so re-running never regenerates the ID or
# overwrites a hostname - it only retries the UUID change.
if [ "$uuid_settled" != yes ]; then
	log "fs UUID not settled; identity will be retried next boot"
	exit 0
fi
mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
if : >"$STAMP" 2>/dev/null; then
	log "per-board identity established"
else
	log "could not write $STAMP; identity will be re-established next boot"
fi
exit 0
