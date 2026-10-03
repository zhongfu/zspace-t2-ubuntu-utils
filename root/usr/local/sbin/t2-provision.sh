#!/bin/sh
SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# ZSpace T2: apply the out-of-band configuration on boot (P3 provisioning).
#
# Source of truth: a FAT partition labelled `t2-config` (the distribution image
# can carry one) holding `t2-config.txt`, a flat key=value list:
#
#     hostname=t2
#     wifi.ssid=MyNet
#     wifi.psk=secret
#     wifi.country=DE
#     ssh.authorized_key=ssh-ed25519 AAAA... you@laptop
#     ble.psk=MySecret
#
# The `install.*` and `flash.*` keys belong to the initramfs installer (it
# reads t2-config.txt itself when the board boots in flash mode); this service
# ignores them like any other key it does not own.
#
# Why this first: it needs no daemon, no browser and no working network - it is
# the only channel that works on a board that was just flashed and has no
# credentials.  One file with a documented key set, not a configuration
# language.
#
# Rules:
#   * the partition is mounted read-only and never modified;
#   * applying is idempotent - the config's sha256 is stamped in
#     /var/lib/t2-provision/applied, so booting again with an unchanged file
#     does nothing, while editing the file re-applies it (that is how WiFi
#     credentials get changed without a keyboard);
#   * a malformed or partial config is logged and ignored, never fatal: a bad
#     config file must not keep a headless board off the network;
#   * no config partition at all is the normal case for the eMMC layout today
#     (the vendor GPT has no free space) and exits 0 immediately;
#   * everything is logged to /var/log/t2-provision.log *and* the journal, so
#     the field can see what happened after a reboot.
set -eu

# Test overrides (same pattern as t2-hddled.sh's LEDS_ROOT and
# t2-growroot.sh's T2_SYSFS_BLOCK): T2_CONFIG_DIR skips the mount and points
# straight at a directory, T2_PROVISION_ROOT relocates every path written.
ROOT=${T2_PROVISION_ROOT:-/}
CONFIG_DIR=${T2_CONFIG_DIR:-}
# The distribution images label the config partition `T2-CONFIG` (uppercase on
# purpose: they are meant to be written from Windows/macOS, where lowercase VFAT
# labels misbehave), while `t2-config` was only ever the documented spelling.
# Accept both, in that order: blkid label matching is case-sensitive, and a
# board that boots with the wrong one silently provisions nothing (measured
# 2026-10-01 on the install card: log said "no 't2-config' partition" while
# `blkid -t LABEL=T2-CONFIG` found it).
LABEL=${T2_CONFIG_LABEL:-T2-CONFIG}
LABELS="T2-CONFIG t2-config"
[ -n "${T2_CONFIG_LABEL:-}" ] && LABELS="$T2_CONFIG_LABEL"

LOG="$ROOT/var/log/t2-provision.log"
STATE="$ROOT/var/lib/t2-provision"
NM_DIR="$ROOT/etc/NetworkManager/system-connections"
KEYS="$ROOT/root/.ssh/authorized_keys"
MNT="$ROOT/run/t2-provision"

log() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
	echo "$(date -Is) t2-provision: $*" >>"$LOG" 2>/dev/null || true
	echo "t2-provision: $*"
}

mkdir -p "$STATE"

# --- find the config ---------------------------------------------------------
if [ -n "$CONFIG_DIR" ]; then
	dir=$CONFIG_DIR
else
	dev=''
	for l in $LABELS; do
		dev=$(blkid -t "LABEL=$l" -o device 2>/dev/null | head -n1 || true)
		[ -n "$dev" ] && break
	done
	if [ -z "$dev" ]; then
		log "no config partition (labels: $LABELS); nothing to provision"
		exit 0
	fi
	mkdir -p "$MNT"
	if ! mount -t vfat -o ro "$dev" "$MNT" 2>/dev/null; then
		log "cannot mount $dev read-only; nothing to provision"
		exit 0
	fi
	trap 'umount "$MNT" 2>/dev/null || true' EXIT
	dir=$MNT
fi

cfg=$dir/t2-config.txt
if [ ! -f "$cfg" ]; then
	log "no t2-config.txt in $dir; nothing to provision"
	exit 0
fi

sum=$(sha256sum "$cfg" | cut -d' ' -f1)
if [ -f "$STATE/applied" ] && [ "$(cat "$STATE/applied")" = "$sum" ]; then
	log "config unchanged ($sum); already applied"
	exit 0
fi
log "applying config $sum from $cfg"

# --- parse -------------------------------------------------------------------
hostname=''
ssid=''
psk=''
country=''
keys=''
blepsk=''

while IFS= read -r raw || [ -n "$raw" ]; do
	line=$(printf '%s' "$raw" | tr -d '\r')
	case "$line" in
	'' | '#'*) continue ;;
	*=*) ;;
	*)
		log "ignoring malformed line: $line"
		continue
		;;
	esac
	key=${line%%=*}
	val=${line#*=}
	case "$key" in
	hostname) hostname=$val ;;
	wifi.ssid) ssid=$val ;;
	wifi.psk) psk=$val ;;
	wifi.country) country=$val ;;
	ble.psk) blepsk=$val ;;
	ssh.authorized_key) keys="${keys}${val}
" ;;
	*) log "ignoring unknown key '$key'" ;;
	esac
done <"$cfg"

# --- apply -------------------------------------------------------------------
if [ -n "$hostname" ]; then
	# the helper rewrites /etc/hosts' 127.0.1.1 line (which otherwise keeps
	# mapping the baked default `t2`) and /etc/hostname; hostnamectl then sets
	# the running name through hostnamed
	"$SELF/t2-sethostname" "$hostname" || true
	if command -v hostnamectl >/dev/null 2>&1; then
		if hostnamectl set-hostname "$hostname"; then
			log "hostname -> $hostname"
		else
			log "hostnamectl could not set the hostname"
		fi
	else
		log "no hostnamectl; hostname not set"
	fi
fi

if [ -n "$blepsk" ]; then
	# The pre-shared key authenticates BLE management clients (t2-ble.py);
	# the file is root-only and rewritten wholesale, so an operator editing
	# ble.psk= rotates the key on the next boot.
	mkdir -p "$ROOT/etc"
	umask 077
	cat >"$ROOT/etc/t2-ble.conf" <<EOF
# written by t2-provision.service from the config partition (ble.psk=).
# t2-ble-password prints the key; delete this file to let t2-ble.service
# generate a fresh random one.
T2_BLE_PSK=$blepsk
EOF
	chmod 600 "$ROOT/etc/t2-ble.conf"
	log "wrote /etc/t2-ble.conf from ble.psk (mode 0600)"
fi

if [ -n "$ssid" ]; then
	if [ -z "$psk" ]; then
		log "wifi.ssid without wifi.psk: refusing to write a network profile"
	else
		mkdir -p "$NM_DIR"
		umask 077
		cat >"$NM_DIR/t2-wifi.nmconnection" <<EOF
[connection]
id=t2-wifi
type=wifi
interface-name=wlp1s0

[wifi]
mode=infrastructure
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto

[ipv6]
method=auto
EOF
		chmod 600 "$NM_DIR/t2-wifi.nmconnection"
		log "wrote NetworkManager profile t2-wifi (ssid=$ssid, mode 0600)"
		if command -v nmcli >/dev/null 2>&1; then
			nmcli con reload >/dev/null 2>&1 || true
			nmcli radio wifi on >/dev/null 2>&1 || true
			if nmcli con up t2-wifi >/dev/null 2>&1; then
				log "t2-wifi brought up"
			else
				log "nmcli could not bring t2-wifi up yet; NetworkManager will retry"
			fi
		fi
	fi
fi

if [ -n "$country" ]; then
	if command -v iw >/dev/null 2>&1; then
		if iw reg set "$country"; then
			log "WiFi regulatory domain -> $country"
		else
			log "iw reg set $country failed"
		fi
	else
		log "wifi.country=$country ignored: no iw in this image"
	fi
fi

if [ -n "$keys" ]; then
	list=$STATE/keys.tmp
	printf '%s' "$keys" >"$list"
	mkdir -p "$(dirname "$KEYS")"
	chmod 700 "$(dirname "$KEYS")"
	[ -f "$KEYS" ] || : >"$KEYS"
	chmod 600 "$KEYS"
	added=0
	while IFS= read -r k; do
		[ -n "$k" ] || continue
		case "$k" in
		ssh-* | ecdsa-* | sk-*) ;;
		*)
			log "ignoring ssh.authorized_key that is not a public key"
			continue
			;;
		esac
		if grep -qxF -- "$k" "$KEYS"; then
			continue
		fi
		printf '%s\n' "$k" >>"$KEYS"
		added=$((added + 1))
	done <"$list"
	rm -f "$list"
	log "authorized_keys: $added key(s) added for root"
fi

# --- stamp -------------------------------------------------------------------
printf '%s\n' "$sum" >"$STATE/applied"
log "config $sum applied; edit $cfg to re-apply"
exit 0
