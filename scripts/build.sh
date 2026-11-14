#!/usr/bin/env bash
#
# Reproducible build of an OpenWrt image for the TP-Link TL-WA854RE v1.
#
# Why this script exists (see README for the full story):
#   1. The WA854RE v1 is the same board as the TL-WA850RE v1 minus the Ethernet
#      port, but its safeloader HWID is 0x08540001 instead of 0x08500001.
#      Stock firmware refuses a 0x08500001 image with errCode 18005.
#   2. Stock OpenWrt images ship /lib/wifi/mac80211.sh with
#      `set wireless.radio${devidx}.disabled=1`, i.e. the radio is OFF on first
#      boot. This device has no Ethernet port, so that leaves no way in.
#   3. The ar71xx/tiny default package set has no LuCI, and the 4 MB flash is
#      too small for the full set plus LuCI, so ppp/swconfig/uboot-envtools are
#      dropped to make room.
#
# Requirements: a LINUX host (or a linux/amd64 container) on a CASE-SENSITIVE
# filesystem, with: bash curl wget tar xz make sed perl python3 rsync unzip file
# gawk. `wget` matters: the ImageBuilder's package fetch shells out to it and
# its own bundled wrapper does not run in a slim container.
#
# Usage:  ./scripts/build.sh [output-dir]
#
set -euo pipefail

REL="18.06.9"
TARGET="ar71xx"
SUBTARGET="tiny"
PROFILE="tl-wa850re-v1"
HWID_FROM="0x08500001"
HWID_TO="0x08540001"

IB="openwrt-imagebuilder-${REL}-${TARGET}-${SUBTARGET}.Linux-x86_64"
IB_SHA256="fe3a478338fb3105aed8f1fc6f8a7485f1bdedbfb2cb4f6f90b3cce4069b338c"
BASE_URL="https://archive.openwrt.org/releases/${REL}/targets/${TARGET}/${SUBTARGET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-${SCRIPT_DIR}/../dist}"
WORK="${WORK:-${SCRIPT_DIR}/../work}"

say() { printf '\n=== %s ===\n' "$*"; }

for t in curl tar xz make sed perl python3 wget; do
  command -v "$t" >/dev/null 2>&1 || { echo "ERROR: required tool '$t' not found in PATH" >&2; exit 1; }
done

say "checking for a case-sensitive filesystem at ${WORK}"
mkdir -p "$WORK"
touch "$WORK/.caseprobe"
if [ -e "$WORK/.CASEPROBE" ]; then
  echo "WARNING: ${WORK} is case-INsensitive; the ImageBuilder build will likely fail." >&2
  echo "         Use a case-sensitive volume (e.g. a Docker named volume)." >&2
fi
rm -f "$WORK/.caseprobe" "$WORK/.CASEPROBE" 2>/dev/null || true

cd "$WORK"

say "fetching ImageBuilder ${REL} (${TARGET}/${SUBTARGET})"
if [ ! -f "${IB}.tar.xz" ]; then
  curl -fL --retry 3 -o "${IB}.tar.xz" "${BASE_URL}/${IB}.tar.xz"
fi

say "verifying ImageBuilder checksum"
echo "${IB_SHA256}  ${IB}.tar.xz" | sha256sum -c -

say "unpacking"
rm -rf "$IB"
tar xf "${IB}.tar.xz"
IBDIR="${WORK}/${IB}"
cd "$IBDIR"

say "patching device definition: TPLINK_HWID ${HWID_FROM} -> ${HWID_TO}"
MK="target/linux/${TARGET}/image/tiny-tp-link.mk"
[ -f "$MK" ] || { echo "ERROR: $MK not found" >&2; exit 1; }
if ! grep -q "TPLINK_HWID := ${HWID_TO}" "$MK"; then
  sed -i "s/TPLINK_HWID := ${HWID_FROM}/TPLINK_HWID := ${HWID_TO}/" "$MK"
fi
grep -c "TPLINK_HWID := ${HWID_TO}" "$MK" | sed 's/^/  occurrences of new HWID: /'

say "checking the vendored files/ overlay (radio must be enabled by default)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FILES_DIR="${REPO_DIR}/files"
[ -f "${FILES_DIR}/lib/wifi/mac80211.sh" ] || {
  echo "ERROR: ${FILES_DIR}/lib/wifi/mac80211.sh missing" >&2; exit 1; }
if grep -q 'radio\${devidx}\.disabled=1' "${FILES_DIR}/lib/wifi/mac80211.sh"; then
  echo "ERROR: vendored mac80211.sh still contains the disabled=1 line." >&2
  echo "       Flashing that image would leave the radio OFF with no way in." >&2
  exit 1
fi
echo "  radio will be ENABLED on first boot"

say "pointing package repositories at archive.openwrt.org (18.06.9 is EOL)"
sed -i 's|http://downloads\.openwrt\.org|http://archive.openwrt.org|g' repositories.conf
grep -c 'archive.openwrt.org' repositories.conf | sed 's/^/  rewritten repo lines: /'

say "building (this takes a few minutes)"
# The ImageBuilder's prereq probes look for host gcc/python2 through its bundled
# toolchain and always fail; the tools that actually generate the image are
# shipped prebuilt, so seed the stamp and pass FORCE=1.
touch staging_dir/host/.prereq-build
rm -rf bin/targets/"${TARGET}"/"${SUBTARGET}"
make image \
  PROFILE="${PROFILE}" \
  PACKAGES="-ppp -ppp-mod-pppoe -swconfig -uboot-envtools luci" \
  FILES="${FILES_DIR}" \
  FORCE=1

say "verifying the built factory image"
FACTORY="$(ls "$IBDIR"/bin/targets/"${TARGET}"/"${SUBTARGET}"/*squashfs-factory.bin | head -1)"
python3 - "$FACTORY" "${HWID_TO}" <<'PY'
import struct, sys, hashlib
path, want = sys.argv[1], sys.argv[2]
d = open(path, 'rb').read()
hwid = struct.unpack('>I', d[0x40:0x44])[0]
ok = (hwid == int(want, 16))
print(f"  file        : {path.split('/')[-1]}")
print(f"  size        : {len(d)} bytes")
print(f"  HWID        : 0x{hwid:08x} ({'OK' if ok else 'WRONG'})")
print(f"  sha256      : {hashlib.sha256(d).hexdigest()}")
sys.exit(0 if ok else 1)
PY

say "collecting artifacts into ${OUT_DIR}"
mkdir -p "$OUT_DIR"
cp "$IBDIR"/bin/targets/"${TARGET}"/"${SUBTARGET}"/*squashfs-factory.bin "$OUT_DIR"/
cp "$IBDIR"/bin/targets/"${TARGET}"/"${SUBTARGET}"/*squashfs-sysupgrade.bin "$OUT_DIR"/
cp "$IBDIR"/bin/targets/"${TARGET}"/"${SUBTARGET}"/*manifest "$OUT_DIR"/ 2>/dev/null || true
( cd "$OUT_DIR" && sha256sum ./*.bin > SHA256SUMS )
ls -l "$OUT_DIR"

say "done"
