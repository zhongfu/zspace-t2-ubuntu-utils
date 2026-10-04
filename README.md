# zspace-t2-ubuntu-utils

The `t2-utils` Debian package: the ZSpace T2 (Rockchip RK3568) board userspace,
and `t2-mkfit`, the tool that assembles the board's boot FIT.

The T2 distribution is split across four repositories.  This one owns the board
userspace and the FIT assembler; it depends on nothing else at build time and
contains no kernel, U-Boot or rootfs content.  The image repository consumes the
built `.deb` through `components.lock` (`tools/components.py`), so a release tag
here names one exact package.

## Contents

Everything installed is under the package root, `root/`, and `build.sh` copies
it verbatim.  The installed paths are the ones the image already used before the
split, because the image's profile hooks, its local apt repo (`/opt/t2/repo`)
and a board that upgrades over apt all read them:

* `etc/systemd/system/t2-*.service` and their `/etc` drop-ins (NetworkManager,
  dnsmasq, sshd, logind, systemd, power-button policy) - the board services;
* `usr/local/sbin/t2-*` - the helper scripts the units call;
* `usr/bin/t2-mkfit` - the boot FIT assembler (see below).

The files under `/etc` are listed in `conffiles`, so local edits survive an
upgrade.  `postinst` re-enables the units best-effort and restores the modes of
the shipped executables; it never fails the dpkg run (the image build has no
running systemd).

## Building

```sh
./build.sh [VERSION] [OUT.deb]
```

`VERSION` defaults to this repository's `git describe --tags --always --dirty`
with a leading `v` stripped (release tags are `v<semver>`), so a development
build from an untagged commit and a tagged release both produce an installable
`.deb`.  `OUT` defaults to `build/t2-utils_<VERSION>_all.deb`.

The build is a hand-written `DEBIAN/` control directory plus `dpkg-deb --build`,
with no debhelper and no `debian/rules`: the package is a flat file tree with
one maintainer script, the build image carries `dpkg` but not `dpkg-dev`, and
`debhelper`'s machinery would only add a build dependency.  `--root-owner-group`
normalises ownership (the build runs unprivileged) and `SOURCE_DATE_EPOCH` pins
the archive member times, so the same tree builds the same bytes.  The
`[VERSION] [OUT.deb]` argument shape is what the image build calls, and it is
unchanged by the split.

## t2-mkfit

```sh
t2-mkfit --kernel Image --dtb rk3568-t2.dtb [--ramdisk initramfs.cpio.gz] \
         [--resource resource.img] --out boot.img
```

`t2-mkfit` writes the Rockchip "external FIT" the board's U-Boot reads: a
flattened device tree whose `/images` sub-images are addressed by
`data-position`/`data-size`, each with a sha256 `hash` node, and one default
`/configurations/conf` naming every present subimage (`kernel`, `fdt`, and
`ramdisk` and the `multi = "resource"` hook when those are given).  The layout
is the vendor's: `[FIT structure, padded to 0x800][fdt][kernel][ramdisk]
[resource]`, with the Rockchip load addresses (fdt `0x08300000`, kernel
`0x00280000`, ramdisk `0x0a200000`) and `rollback-index = 0`; there is no
signature node because the vendor FIT is unsigned.

The structure is serialised by the tool itself rather than by `dtc`: the board
image ships no device-tree-compiler, and it installs this package from a
`file:` apt repo, so a new runtime dependency could not be satisfied offline.
The result is parsed back after writing - every subimage hash and the default
configuration are checked - so a malformed FIT is a failed build, not a failed
boot.  The tool needs only `python3`.

`--ramdisk` takes a gzip'd cpio initramfs and stores it uncompressed: this
U-Boot skips decompression for FIT ramdisks (the `compression` property there is
deprecated), so the initrd reaches the kernel as a plain cpio.  An input that is
already a raw archive, or empty, is stored as-is.

## Releases

Two GitHub Actions workflows mirror the rest of the T2 repositories:

* `build.yml` runs on branch pushes and pull requests: it builds the `.deb`,
  prints `dpkg-deb -I` and `dpkg-deb -c`, smoke-tests `t2-mkfit`, and uploads
  the `.deb`.
* `release.yml` runs on a `v*` tag: it builds the `.deb`, assembles a *signed*
  flat apt repository (`apt-ftparchive` plus a clearsigned `Release`), publishes
  the repository to GitHub Pages, and attaches `t2-utils_<version>_all.deb` and
  `apt-repo.tar.gz` to the release.

Signing uses the repository secrets `APT_SIGNING_KEY` (the ASCII-armoured
private key) and `APT_SIGNING_KEY_ID` (its key id).  The runner label follows the
other repositories: the release job honours the `T2_RELEASE_RUNNER` repository
variable and falls back to `ubuntu-latest`.

A board points apt at the published Pages URL for upgrades; the same package
ships inside the image at `/opt/t2/repo` with `[trusted=yes]`, so an offline
board can reinstall or upgrade without reflashing.
