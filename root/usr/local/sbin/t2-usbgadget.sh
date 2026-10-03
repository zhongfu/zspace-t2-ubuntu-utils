#!/bin/sh
# ZSpace T2: bring up the USB device-mode gadget (P3 out-of-band provisioning).
#
# Plug the board into a laptop and you get:
#   * a network interface - one CDC-NCM function, which every current host OS
#     drives with an in-box driver (Linux/BSD cdc_ncm, macOS, Windows 10 1709+);
#     the board is 10.55.55.2/24 and dnsmasq hands the laptop 10.55.55.10-50
#     (see /etc/dnsmasq.d/t2-usbgadget.conf).  avahi already runs on the image,
#     so `ssh root@t2.local` also works over this link without knowing the
#     address.
#   * optionally a USB drive: the T2-CONFIG partition exported as a mass
#     storage LUN, i.e. the *writable* half of the provisioning channel - edit
#     `t2-config.txt` from the laptop and the board applies it on the next boot
#     (t2-provision.service).
#
# Why the distro owns this: the shipped FIT carries kernel + DTB only (no
# ramdisk), so nothing else in the boot chain configures a gadget.
#
# One UDC, one config: the functions that cannot be honoured are simply left
# out (no T2-CONFIG partition -> no mass storage), and a missing UDC (the port
# is a host port today, or the cable is not attached) is a logged no-op, never
# a boot failure.
#
# The gadget is *supervised*: one pass puts it in the state the board wants,
# and the service then repeats that pass every POLL_INTERVAL seconds (the
# `supervise` block at the bottom).  A configfs gadget does not heal itself -
# measured 2026-10-03, pulling the SD card out from under the exported LUN cost
# the host the *whole* gadget, and the old one-shot script had already exited,
# so nothing rebuilt it.  A pass watches two things: the gadget is still bound,
# and the config drive matches the intent (exported exactly when a T2-CONFIG
# partition exists, is not mounted, and is not on the disk the rootfs runs
# from) - so a card that comes or goes changes the gadget, instead of leaving a
# LUN exporting a dead file.
#
# Test override (same pattern as the other t2-* scripts): CONFIGFS_ROOT points
# at a fake configfs tree, SYS_NET at a fake network class dir, UDC_NAME forces
# a UDC, NO_DHCP/NET_CMD skip or replace the interface configuration, and
# SUPERVISE=0 runs a single pass (what the tests use, bounded further by
# POLL_INTERVAL/MAX_ITERATIONS).
set -eu

CONFIGFS=${CONFIGFS_ROOT:-/sys/kernel/config}
SYS_NET=${SYS_NET:-/sys/class/net}
UDC=${UDC_NAME:-}
LABEL=${T2_CONFIG_LABEL:-T2-CONFIG}
GADGET=$CONFIGFS/usb_gadget/t2
NET_CMD=${NET_CMD:-ip}
NO_DHCP=${NO_DHCP:-}
SUPERVISE=${SUPERVISE:-1}
# 20 s, not 5: a pass forks a shell plus blkid and findmnt, which measured
# ~3 % of one core at 5 s - too much for an always-on board - and nothing about
# this link needs sub-20 s recovery (the gadget survives a cable replug on its
# own; only a lost binding or a card change needs a rebuild).
POLL_INTERVAL=${POLL_INTERVAL:-20}
MAX_ITERATIONS=${MAX_ITERATIONS:-0}   # 0 = until killed (the t2-hddled test hook)
ADDR=10.55.55.2/24
IFACES="usb0"

log() { echo "t2-usbgadget: $*"; }

# --- what the gadget should look like ----------------------------------------
# The config drive is a convenience, never a requirement, and it may only go
# out when exporting it is safe: a mounted filesystem must not be handed to the
# host read-write (corruption race), and a partition of the disk we are
# *running from* cannot be exported at all - the kernel refuses the LUN
# outright (measured on the install card, which keeps its rootfs on the same
# card as the config partition: 2026-10-01, "echo: I/O error" on lun.0/file).
# Skipping the drive is the right call there: the link is the point.
disk_of() { # partition or whole disk -> the whole disk
	d=$(readlink -f "$1" 2>/dev/null || echo "$1")
	case "$d" in
	/dev/mmcblk*) echo "${d%%p[0-9]*}" ;;
	/dev/sd*[0-9]) echo "${d%[0-9]}" ;;
	/dev/nvme*|/dev/loop*) echo "${d%%p[0-9]}" ;;
	*) echo "$d" ;;
	esac
}

config_dev() { # the T2-CONFIG partition, if there is one at all
	blkid -t "LABEL=$LABEL" -o device 2>/dev/null | head -n1 || true
}

config_exportable_dev() {
	# Sets EXPORT_DEV (the device, if there is one) and EXPORT_SKIP ("" when it
	# may be exported, else why not).  Deliberately not a function that echoes
	# the device: the decision and its reason are globals, and a command
	# substitution would run them in a subshell where they are lost.
	EXPORT_DEV=$(config_dev)
	EXPORT_SKIP=
	if [ -z "$EXPORT_DEV" ]; then
		EXPORT_SKIP=none
		return 0
	fi
	if findmnt -no TARGET "$EXPORT_DEV" >/dev/null 2>&1; then
		EXPORT_SKIP=mounted
		return 0
	fi
	root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	if [ -n "$root_dev" ] && [ "$(disk_of "$EXPORT_DEV")" = "$(disk_of "$root_dev")" ]; then
		EXPORT_SKIP=rootfs
		return 0
	fi
}

export_config_drive() {
	config_exportable_dev
	if [ -n "$EXPORT_SKIP" ]; then
		case "$EXPORT_SKIP" in
		mounted) log "$EXPORT_DEV is mounted; not exporting it as a USB drive" ;;
		rootfs)  log "$EXPORT_DEV is on $(disk_of "$EXPORT_DEV"), the disk this rootfs runs from; not exporting it" ;;
		*)       log "no '$LABEL' partition; the gadget carries the network only" ;;
		esac
		return 0
	fi
	dev=$EXPORT_DEV
	# Critical part: the backing file and the link into the configuration.  If
	# either fails there is nothing to export, and a half-built function is
	# worse than none - the host would see a drive with no medium.  This is
	# the failure the kernel does produce (measured 2026-10-01: EIO on
	# lun.0/file for a partition of the disk the rootfs runs from, which under
	# this script's top-level `set -e` aborted the unit *before* the bind, so
	# the host saw no device at all - and the network link, the half that
	# actually matters, never came up).  `&&`, not `set -e`: inside a
	# condition POSIX shells ignore -e, so the chain is what makes the status
	# meaningful.
	if ! (
		mkdir -p "$GADGET/functions/mass_storage.usb0/lun.0" &&
		echo "$dev" > "$GADGET/functions/mass_storage.usb0/lun.0/file" &&
		ln -s "$GADGET/functions/mass_storage.usb0" \
			"$GADGET/configs/c.1/mass_storage.usb0"
	); then
		rm -f "$GADGET/configs/c.1/mass_storage.usb0"
		rmdir "$GADGET/functions/mass_storage.usb0/lun.0" 2>/dev/null || true
		rmdir "$GADGET/functions/mass_storage.usb0" 2>/dev/null || true
		log "kernel refused the LUN for $dev; carrying the network only"
		return 0
	fi
	# Cosmetic, and deliberately best effort: the kernel can refuse these while
	# the LUN itself is fine - measured 2026-10-03, `ro` returned EBUSY because
	# the device was still held by the previous gadget's LUN, while `file` took
	# it and the host saw the drive.  Refusing the drive over the removable bit
	# or the inquiry string would be the wrong trade.
	echo 1 > "$GADGET/functions/mass_storage.usb0/lun.0/removable" 2>/dev/null || true
	echo 0 > "$GADGET/functions/mass_storage.usb0/lun.0/ro" 2>/dev/null || true
	echo "T2-CONFIG" > "$GADGET/functions/mass_storage.usb0/lun.0/inquiry_string" 2>/dev/null || true
	log "exporting $dev as a USB drive (edit t2-config.txt from the host)"
}

want_lun() { # yes/no: should the config drive be part of the gadget right now
	config_exportable_dev
	[ -n "$EXPORT_DEV" ] && [ -z "$EXPORT_SKIP" ] && echo yes || echo no
}

have_lun() { # yes/no: is the config drive part of the gadget right now
	[ -L "$GADGET/configs/c.1/mass_storage.usb0" ] && echo yes || echo no
}

bound() { [ -n "$(cat "$GADGET/UDC" 2>/dev/null || true)" ]; }

in_sync() { # the gadget is exactly what the board currently wants
	bound && [ "$(have_lun)" = "$(want_lun)" ]
}

# --- main --------------------------------------------------------------------
if [ ! -d "$CONFIGFS/usb_gadget" ]; then
	log "no usb_gadget configfs at $CONFIGFS; nothing to do"
	exit 0
fi

if [ -z "$UDC" ]; then
	for d in /sys/class/udc/*; do
		[ -e "$d" ] || continue
		UDC=${d##*/}
		break
	done
fi

# A supervisor pass (T2_USBGADGET_CHECK=1, spawned by the loop at the bottom)
# only rebuilds when the gadget no longer matches the intent.  A plain run
# always rebuilds, because a boot must not inherit a half-built gadget from an
# earlier life.
if [ "${T2_USBGADGET_CHECK:-}" = 1 ]; then
	if in_sync; then
		exit 0
	fi
	log "gadget out of sync (bound=$(bound && echo yes || echo no), config drive=$(have_lun), wanted=$(want_lun)); rebuilding"
fi

if [ -z "$UDC" ]; then
	log "no UDC (device port not available: cable unplugged or host-only mode)"
	exit 0
fi

# --- tear down anything left from an earlier bind ----------------------------
teardown() {
	if [ -e "$GADGET/UDC" ] && [ -s "$GADGET/UDC" ]; then
		# best effort like the rest of the teardown; the kernel can return EIO
		# here when a rebind is already in flight, and `echo: I/O error` in the
		# journal reads like a bug when it is not one
		echo "" > "$GADGET/UDC" 2>/dev/null || true
	fi
	for f in "$GADGET"/configs/*/; do
		[ -d "$f" ] || continue
		for l in "$f"*/; do
			[ -L "${l%/}" ] && rm -f "${l%/}" || true
		done
		rmdir "$f" 2>/dev/null || true
	done
	for f in "$GADGET"/functions/*/; do
		# a stale LUN export must not survive: it would expose a partition this
		# run decided not to export
		[ -e "${f%/}/lun.0/file" ] && echo "" > "${f%/}/lun.0/file" 2>/dev/null || true
		[ -d "$f" ] && rmdir "${f%/}" 2>/dev/null || true
	done
	rmdir "$GADGET" 2>/dev/null || true
}
teardown

# --- build -------------------------------------------------------------------
mkdir -p "$GADGET"
echo 0x2207 > "$GADGET/idVendor"      # Rockchip's vendor id, as the vendor uses
echo 0x0006 > "$GADGET/idProduct"
echo 0x0200 > "$GADGET/bcdUSB"
echo 0x0100 > "$GADGET/bcdDevice"
mkdir -p "$GADGET/strings/0x409"
echo "ZSpace" > "$GADGET/strings/0x409/manufacturer"
echo "T2 provisioning link" > "$GADGET/strings/0x409/product"
echo "$(cat /etc/hostname 2>/dev/null || echo t2)" > "$GADGET/strings/0x409/serialnumber"
mkdir -p "$GADGET/configs/c.1/strings/0x409"
echo "T2 provisioning" > "$GADGET/configs/c.1/strings/0x409/configuration"
echo 250 > "$GADGET/configs/c.1/MaxPower"

# One network function: CDC-NCM.  NCM is the standards-based replacement for
# both of the older choices and is served by an in-box driver on every current
# host OS (Linux/BSD `cdc_ncm`, macOS since its iOS-tethering days, Windows 10
# 1709+/11 `usbncm.sys`).  It also removes the failure mode the two-function
# gadget had: ECM + RNDIS in one configuration gave a Linux host *two* `enx…`
# interfaces, and the RNDIS one took a DHCP lease from the board and then
# passed no traffic at all (measured 2026-10-02), so every Linux user had to be
# told which of the two was real.  RNDIS is deprecated on Windows as well, so
# nothing is lost by dropping it; only pre-1709 Windows would have needed it.
mkdir -p "$GADGET/functions/ncm.usb0"
ln -s "$GADGET/functions/ncm.usb0" "$GADGET/configs/c.1/ncm.usb0"

# the config drive, when exporting it is safe (config_exportable_dev above)
export_config_drive

# --- bind --------------------------------------------------------------------
echo "$UDC" > "$GADGET/UDC"
log "gadget bound to $UDC (CDC-NCM)"

# --- board side of the link ---------------------------------------------------
# NetworkManager must keep its hands off these interfaces (the overlay ships
# that drop-in); the address and DHCP are ours.  Idempotent, and re-applied on
# every pass: a rebuild destroys and recreates usb0, so it needs the address
# back.
if [ -z "$NO_DHCP" ] || [ "$NO_DHCP" = "0" ]; then
	for i in $IFACES; do
		[ -d "$SYS_NET/$i" ] || continue
		"$NET_CMD" addr add "$ADDR" dev "$i" 2>/dev/null || true
		"$NET_CMD" link set "$i" up 2>/dev/null || true
		log "configured $i with $ADDR"
	done
fi

# the DHCP server itself is dnsmasq.service with an interface-scoped drop-in
# (etc/dnsmasq.d/t2-usbgadget.conf, bind-dynamic, so it tolerates usb0
# appearing after it starts)

# --- supervise ----------------------------------------------------------------
# One pass has just put the gadget in the state the board wants.  Keep it that
# way by re-running this same script in check-first mode every POLL_INTERVAL:
# a gadget that lost its binding (the kernel clears UDC when the UDC goes away,
# e.g. the port flips to host mode) or a config drive whose card came or went
# is rebuilt, and a healthy gadget is left alone - a rebuild is visible to the
# host (the device disconnects and re-enumerates), so it must not happen for no
# reason.  The unit's Restart=always is the outer layer: it covers this process
# dying, which this loop does not.
if [ "$SUPERVISE" != 0 ]; then
	trap 'log "stopping; removing the gadget"; teardown; exit 0' TERM INT
	n=0
	while :; do
		n=$((n + 1))
		if [ "$MAX_ITERATIONS" != 0 ] && [ "$n" -gt "$MAX_ITERATIONS" ]; then
			break
		fi
		sleep "$POLL_INTERVAL"
		if T2_USBGADGET_CHECK=1 SUPERVISE=0 sh "$0"; then
			continue
		fi
		log "a check pass failed; retrying in ${POLL_INTERVAL}s"
	done
fi
exit 0
