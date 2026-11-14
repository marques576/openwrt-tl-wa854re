# OpenWrt for the TP-Link TL-WA854RE v1

Unofficial, self-built OpenWrt firmware for the **TP-Link TL-WA854RE v1** wall-plug
range extender, plus the steps to install it.

![TP-Link TL-WA854RE](docs/device-tl-wa854re.png)

*Product image (c) TP-Link, used only to identify the hardware.*

The device is **not** in OpenWrt's Table of Hardware, and the last OpenWrt release
that can build a working image for it is **18.06.9**. This repo contains a patched
image that boots and is reachable on a device with **no Ethernet port**.

> ⚠️ Flashing replaces your stock firmware. There is no Ethernet port on this
> device, so read [Recovery](#recovery) *before* you flash.

---

## Device

| | |
|---|---|
| Model | TP-Link TL-WA854RE v1.0 |
| SoC | Qualcomm Atheros **AR9341 rev 3** (MIPS 74Kc, 535 MHz) |
| RAM | **32 MB** |
| Flash | **4 MB** (Winbond `w25q32`) |
| Wi-Fi | 2.4 GHz 802.11b/g/n, 2×2, one radio |
| Ethernet | **none** — management is Wi-Fi only |
| Console | UART pads on the PCB, 115200 8N1, 3.3 V; case is ultrasonic-welded |
| Bootloader | U-Boot / TP-Link "MyLoader" |

The TL-WA854RE v1 is the same board as the **TL-WA850RE v1** minus the RJ45 port.
That is why an `ar71xx/tiny` build for the `tl-wa850re-v1` profile works here.

---

## Why this image exists

Three separate problems make every "just download the official image" path fail:

**1. Hardware ID mismatch.**
The WA850RE v1 image carries `TPLINK_HWID = 0x08500001`. The WA854RE v1 bootloader
expects `0x08540001`, so stock firmware rejects it:

```
Error code: 18005      # ERR_SYS_FILE_VER
```

**2. The radio is disabled by default.**
Stock OpenWrt ships `/lib/wifi/mac80211.sh` containing:

```diff
-			set wireless.radio${devidx}.disabled=1
```

`/etc/hotplug.d/ieee80211/10-wifi-detect` runs `wifi config`, which generates
`/etc/config/wireless` from that script. The result: **first boot has no Wi-Fi**.
On a device with no Ethernet port that means no LAN, no SSH, no LuCI — the only way
back in is the UART pads. This is the single most common way to "brick" one of these.

**3. It doesn't fit.**
4 MB flash / 32 MB RAM ("4/32"). OpenWrt dropped these after 19.07, and the
`ar71xx/tiny` default package set contains no LuCI. The full default set **plus**
LuCI overflows the flash by ~2.7 KB.

## What this image changes

Built from OpenWrt **18.06.9**, target `ar71xx`, subtarget `tiny`, profile
`tl-wa850re-v1`:

| Change | Reason |
|---|---|
| `TPLINK_HWID := 0x08540001` in `tiny-tp-link.mk` | stock firmware accepts the image |
| `files/lib/wifi/mac80211.sh` — removed the `disabled=1` line | radio on at first boot |
| `+luci` | the tiny default set has no web UI |
| `-ppp -ppp-mod-pppoe -swconfig -uboot-envtools` | free enough flash for LuCI |

`files/lib/wifi/mac80211.sh` is the unmodified OpenWrt 18.06.9 file with exactly one
line deleted, so it is easy to audit:

```diff
--- a/lib/wifi/mac80211.sh        2020-11-11 20:09:58
+++ b/lib/wifi/mac80211.sh
@@ -113,7 +113,6 @@
 			set wireless.radio${devidx}.hwmode=11${mode_band}
 			${dev_id}
 			${ht_capab}
-			set wireless.radio${devidx}.disabled=1
 
 			set wireless.default_radio${devidx}=wifi-iface
 			set wireless.default_radio${devidx}.device=radio${devidx}
```

Resulting image, verified on real hardware: factory image is exactly
**3932160 bytes**, HWID `0x08540001`, kernel region **byte-identical** to the
official 18.06.9 `tl-wa850re-v1` release, rootfs 2174814 bytes (fits the 4 MB
layout with headroom), `mac80211.sh` patched, LuCI + dropbear present.

---

## Images

See [`images/`](images/) and `images/SHA256SUMS`.

| File | Use |
|---|---|
| `*-squashfs-factory.bin` | flash from **stock TP-Link** firmware (web UI) |
| `*-squashfs-sysupgrade.bin` | flash from **OpenWrt** (sysupgrade / LuCI) |
| `*.manifest` | package list of the build |

```bash
sha256sum -c SHA256SUMS
```

These images are 18.06 line software: **end-of-life and unpatched**. They are fine
for a home extender; do not put one on an untrusted network.

---

## Install

### From stock TP-Link firmware

1. Note the device's current IP and admin login (defaults are `192.168.1.1` or
   `tplinkrepeater.net`, user/password `admin`).
2. **There is no way to back up the stock flash** — this is a one-way, destructive step.
3. Open the stock web UI → **System Tools → Firmware Upgrade**.
4. Upload the **factory** image (`*-squashfs-factory.bin`).
5. The device reboots. **Do not power it off mid-flash.**

If you instead get `Error code: 18005`, the uploaded image's HWID does not match the
device. That is a clean refusal (nothing was written). Double-check you are on a
WA854RE v1 and not a different revision.

### First boot

- The device comes up as an **open** network named **`OpenWrt`** at **`192.168.1.1`**
- Join it, open `http://192.168.1.1` (LuCI) → **System → Administration** →
  **set a root password** (this also enables SSH — dropbear will not start until a
  password exists)
- SSH: `ssh root@192.168.1.1` (add `-o HostKeyAlgorithms=+ssh-rsa` on modern OpenSSH,
  because 18.06's dropbear only offers an `ssh-rsa` host key)

> The default LAN address is `192.168.1.1`. If your existing router already uses that
> address, change it under *Network → Interfaces* to avoid a subnet conflict.

---

## Recovery

**Reset button (works for the common case).**
Hold the RESET button ~10 seconds while powered. OpenWrt's button handler runs
`firstboot` and reboots: back to the open `OpenWrt` SSID on `192.168.1.1`, no password.

**UART (last resort).** If the wireless config is bad enough that no AP starts, the
serial pads are the only way in:

1. Open the case (ultrasonic-welded — no screws)
2. Connect a **3.3 V** USB-TTL adapter to the UART pads (TX/RX/GND), **115200 8N1**
3. Interrupt U-Boot, or let OpenWrt boot and use **failsafe mode**
   (press `f` at the preinit prompt), then:
   ```
   mount_root
   rm /etc/config/wireless      # or fix it
   reboot
   ```

---

## Build from source

Reproduces the image with OpenWrt's own ImageBuilder (no full toolchain build).
Requires a **Linux** host **or** a `linux/amd64` container, on a **case-sensitive**
filesystem.

```bash
docker volume create owrtbuild
docker run --rm --platform linux/amd64 \
  -v owrtbuild:/work \
  -v "$PWD":/repo:ro \
  ubuntu:24.04 bash -c '
    apt-get update -qq &&
    apt-get install -y -qq make curl wget tar xz-utils sed perl python3 \
        rsync unzip file gawk ca-certificates >/dev/null &&
    WORK=/work bash /repo/scripts/build.sh /work/dist'
```

Output lands in `/work/dist`. Copy it out with:

```bash
docker run --rm -v owrtbuild:/work -v "$PWD/dist:/out" ubuntu:24.04 \
  bash -c 'cp /work/dist/* /out/ && chmod 644 /out/*'
```

`scripts/build.sh` will:

1. Download the 18.06.9 `ar71xx/tiny` ImageBuilder and verify its SHA256
2. Rewrite the package repos to `archive.openwrt.org` (18.06.9 is EOL)
3. Set `TPLINK_HWID := 0x08540001`
4. Refuse to continue if `files/lib/wifi/mac80211.sh` still disables the radio
5. Build with `FILES=files/` and the package set above
6. Verify the output's HWID and print its SHA256

Re-running it produces a **functionally identical** image with a different hash, because
`squashfs` embeds build timestamps.

Reference checksums used by the script:

```
fe3a478338fb3105aed8f1fc6f8a7485f1bdedbfb2cb4f6f90b3cce4069b338c  openwrt-imagebuilder-18.06.9-ar71xx-tiny.Linux-x86_64.tar.xz
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Stock UI: `Error code 18005` | HWID mismatch — you need this repo's image, not the official `tl-wa850re-v1` one |
| Flashed, then no `OpenWrt` network appears | Radio disabled by default — make sure you used this image, then RECOVERY |
| `ssh` fails: *no matching host key type* | `-o HostKeyAlgorithms=+ssh-rsa` |
| `ssh` connection refused on port 22 | No root password set — set one in LuCI, dropbear starts afterwards |

---

## Notes and limitations

- **4 MB flash / 32 MB RAM**: ~156 KB of overlay free after LuCI. Do not plan on
  installing packages. RAM is the tighter constraint; keep services minimal.
- **18.06.9 is EOL.** No security updates. Home/lab use only.
- **No Ethernet port**, so Wi-Fi is both the service and the only management path.
- The stock firmware on these units is sometimes cross-flashed from a TL-WA850RE, so
  the hardware-version string reported in the stock UI can be misleading. Trust the
  label, and note that `0x08540001` is the identifier the bootloader checks.

## License

The firmware images are built from [OpenWrt](https://openwrt.org), which is free
software under the GPL and other licenses. `files/lib/wifi/mac80211.sh` is an
unmodified OpenWrt file minus one line, and remains under its original license.
This repository only repackages those works.

Not affiliated with or endorsed by TP-Link or the OpenWrt project.
