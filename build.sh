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
#   VERSION  defaults to this repo's `git describe --tags --always --dirty`,
#            with a leading `v` stripped (the release tags are v<semver>)
#   OUT      defaults to <repo>/build/t2-utils_<VERSION>_all.deb
#
# The image build passes the profile release and a path under its own output
# tree, so it and a hand run use one builder and agree on the .deb.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$here

version=${1:-}
if [ -z "$version" ]; then
    # `--always` still yields a version with no tags (a bare commit id), so a
    # development build and a release build both produce an installable .deb.
    desc=$(git -C "$repo" describe --tags --always --dirty 2>/dev/null || echo unknown)
    version=${desc#v}
    version=$(printf '%s' "$version" | sed 's/[^0-9A-Za-z.+~-]//g')
    # a bare commit id is a valid describe result but not a valid Debian
    # version, which must start with a digit; a tagged build is already
    # v<semver> and unaffected
    case "$version" in
        [0-9]*) ;;
        *) version="0.0.0~$version" ;;
    esac
fi
out=${2:-$repo/build/t2-utils_${version}_all.deb}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

mkdir -p "$work/DEBIAN"
# du -sb counts apparent bytes, not allocated blocks: du -sk varies with the
# filesystem's block size and directory slack, so two builds of the same tree
# could put a different Installed-Size in the control member and hash
# differently.  Kilo is 1024 here, matching dpkg.
installed_size=$(( ($(du -sb "$here/root" | cut -f1) + 1023) / 1024 ))
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
