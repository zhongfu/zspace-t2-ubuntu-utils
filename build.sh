#!/bin/sh
# Build the t2-utils Debian package from this directory.
#
# A hand-written DEBIAN/ control directory plus `dpkg-deb --build` (no
# debhelper, no debian/rules): the build image carries dpkg but not dpkg-dev,
# and this package is a flat file tree with one maintainer script, so
# debhelper's dh_installdirs/dh_install* machinery would only add a build
# dependency and a source package nobody builds.  `--root-owner-group`
# normalises the uid/gid (the build runs unprivileged), and SOURCE_DATE_EPOCH
# pins every ar/tar member mtime, so the same tree builds the same .deb bytes.
#
# Usage: build.sh [VERSION] [OUT.deb]
#   VERSION  defaults to the profile-release-independent fallback
#            0.1.0~<git describe --tags --always --dirty>
#   OUT      defaults to <repo>/build/rootfs/t2-utils_<VERSION>_all.deb
#
# rootfs/t2-distro.py calls this with the version it derives from the profile
# (base.json `release`), so the driver and a hand run agree on one builder.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)

version=${1:-}
if [ -z "$version" ]; then
    desc=$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo unknown)
    version="0.1.0~$(printf '%s' "$desc" | sed 's/[^0-9A-Za-z.+~]//g')"
fi
out=${2:-$repo/build/rootfs/t2-utils_${version}_all.deb}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

mkdir -p "$work/DEBIAN"
installed_size=$(du -sk "$here/root" | cut -f1)
sed -e "s/@VERSION@/$version/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    "$here/control.in" > "$work/DEBIAN/control"
cp "$here/conffiles" "$work/DEBIAN/conffiles"
cp "$here/postinst" "$work/DEBIAN/postinst"
chmod 755 "$work/DEBIAN/postinst"

# the payload, modes preserved; ownership is normalised by --root-owner-group
cp -a "$here/root/." "$work/"

# Reproducible: dpkg-deb clamps every member mtime to SOURCE_DATE_EPOCH.
: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH

mkdir -p "$(dirname "$out")"
dpkg-deb --root-owner-group --build "$work" "$out" >/dev/null
echo "$out"
