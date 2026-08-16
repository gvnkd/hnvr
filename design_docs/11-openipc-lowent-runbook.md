# 11 — OpenIPC on low_ent (IPC_GK7205V300_G6S): install runbook

**STATUS: EXECUTED Aug 16 2026 ~11:00 — Path A succeeded.** Post-flash
state + deviations from the plan below (search "DEVIATIONS").

Aug 16 2026. Target: `low_ent` @ 192.168.0.198 (XM DVRIP admin/io27pJ3wui).
Probed facts: SoC Goke **GK7205V300** (OpenIPC stage DONE, recommended),
flash **16 MB NOR** (stock mtdparts sum = 0x1000000), RAM 128 MB (coupler
`totalmem=128M`; stock `osmem=48M` hides it), sensor imx335-class 5MP
(3072×2048 main is upscaled; `sysconfig.ko` whitelist: imx335/imx307/
imx327/imx206/sc2231/sc2235/sc3235/sc4236/gc2053).

## Files (archived at `/home/pion/hw-backups/low_ent-699Q3/`, SHA256SUMS)

| File | What | sha256 (short) |
|---|---|---|
| `coupler-699Q3.bin` | OpenIPC coupler image, **exact** device match | 4cae6bc5… |
| `699Q3_recovery.img` | Stock XM-DVR full-flash recovery image | 60f4ed79… |
| `000699Q3.zip` | Official stock firmware (tehno32.ru, 20250324) | 6361ded8… |

Coupler InstallDesc: Hardware `IPC_GK7205V300_G6S` (native match — no
SkipCheck repack needed), burns uImage + rootfs + u-boot.env +
mtd-x.jffs2, **keeps stock u-boot**. New layout: 256k(boot),64k(wtf),
2048k(kernel),5120k(rootfs),-(rootfs_data); `osmem=32M`.

## Path A — Coupler via DVRIP (primary; no disassembly)

The upload channel is proven on this exact camera (Aug 16 session:
SkipCheck InstallDesc → Ret 515). Camera will be down ~3–5 min; HNVR
capture worker backoff handles it. Have the UART adapter nearby anyway.

```bash
python3 - <<'EOF'
import sys
sys.path.insert(0, '/tmp/opencode/python-dvr')
from dvrip import DVRIPCam
c = DVRIPCam('192.168.0.198', user='admin', password='io27pJ3wui')
print('login:', c.login())
print('upgrade:', c.upgrade('/home/pion/hw-backups/low_ent-699Q3/coupler-699Q3.bin'))
c.close()
EOF
```

(Equivalent: stock web UI → System → Upgrade, same .bin.)

After flash the camera **DHCPs a new address** — watch the lease/ARP.
Then:

1. `ssh root@<new-ip>` — default password `openipc`.
2. `firstboot` (clean overlay), `reboot`.
3. `ipctool` / `fw_printenv sensor` — if `unknown`, set
   `fw_setenv sensor imx335` (next candidates: sc4236, sc3235) and reboot.
4. Web UI (Majestic) at `http://<ip>/` — set static IP 192.168.0.198,
   change root password, check image.

Risks: coupler is WIP; if Burn dies midway → UART recovery (below).

## Path B — UART (canonical / recovery; adapter required)

1. **Wiring**: USB-UART (FTTI/CP2102) at **3.3 V** (5 V kills the board).
   4-pin unpopulated header on the main PCB: find GND with a multimeter
   (continuity to screw holes / shield), TX = pad spewing data at boot,
   RX = the remaining 3.3 V pad that echoes. Don't use the VCC pin —
   power via the camera's own PSU.
2. **Console**: `picocom -b 115200 --logfile boot.log /dev/ttyUSB0`.
3. **Interrupt autoboot**: XM u-boot = **Ctrl-C** spam right at power-on.
   ⚠ 2024 XM firmware may password-protect the u-boot shell. If a password
   prompt appears: options = (a) skip to Path A, (b) short pins 5–6 of the
   SOIC8 NOR while booting (forces u-boot shell), (c) downgrade stock via
   DVRIP to a pre-2021-07 build first.
4. **Full backup** (mandatory before any manual flash; stock u-boot has no
   `tftpput` — UART dump it, ~1–2 h for 16 MB):
   ```screen
   mw.b 0x42000000 0xff 0x1000000
   sf probe 0
   sf read 0x42000000 0x0 0x1000000
   md.b 0x42000000 0x1000000
   ```
   Convert: `cat boot.log | sed -E "s/^[0-9a-f]{8}\b: //i" | sed -E "s/ {4}.{16}\r?$//" > d.hex && xxd -r -p d.hex low_ent-stock-16m.bin`
   (expect exactly 16777216 bytes; store next to the other images).
5. **Flash OpenIPC full image** (from openipc.org supported-hardware →
   GK7205V300, NOR 16M, Ultimate → "Alternative method" binary), TFTP:
   ```screen
   setenv ipaddr 192.168.0.198; setenv serverip <tftp-host>
   mw.b 0x42000000 0xff 0x1000000
   tftpboot 0x42000000 openipc-gk7205v300-ultimate-16mb.bin
   sf probe 0; sf erase 0x0 0x1000000; sf write 0x42000000 0x0 ${filesize}
   reset
   ```
   (XM quirk: if `sf write` is refused, `flwrite` after `tftpboot` instead.)
   First boot: interrupt again, `run setnor16m`, boot, `firstboot`.

## Recovery

- **Stock u-boot alive** → serve `699Q3_recovery.img` from TFTP as
  `mtd-x.jffs2.img`, then at the u-boot prompt run the stock macro:
  `run dd` (= tftpboot + flwrite, full-chip). Reboot → back to stock XM.
  (Or flash our own 16 MB dump per Path B step 5 write commands.)
- **u-boot dead** → SOIC8 test clip + flashrom on the 16 MB NOR
  (25Q128-class), write the Path-B dump or recovery image @ offset 0.

## Post-flash HNVR changes

- `cameras` row (low_ent): new RTSP URLs from Majestic (default
  `rtsp://ip:554/live/0` main, `/live/1` sub — confirm via Majestic web UI
  "docs"; no RTSP auth by default, creds → NULL), `onvif_port` per OpenIPC
  ONVIF addon or NULL, `model_name` = "OpenIPC GK7205V300".
- Re-run ProbeCameraAction (ffprobe owns codec fields).
- **The payoff**: Majestic exposes per-stream fps/res/bitrate — set sub to
  640×360 @15 fps (fixes the stock 5 fps CV borderline case).
- Gone after flash: DVRIP :34567 (python-dvr), XM web UI, and the leftover
  telnetd :50119 from the Aug 16 session (whole flash is rewritten —
  verify the port is closed).
- 196/197 are untouched (different OEM firmware, not coupler targets).

## Rollback cost

Coupler → stock is UART-only (TFTP recovery above). Budget for opening
the case once if anything goes sideways.

## DEVIATIONS (as-executed, Aug 16 2026)

- Coupler default SSH password: **`12345`**, not `openipc`.
- `firstboot` ran BEFORE any config (correct order: it wipes the
  overlay → password/network/majestic edits after).
- RTSP URL form is **query-style**: `rtsp://root:<pw>@192.168.0.198:554/stream=0`
  (main) and `.../stream=1` (sub). Path-form URLs silently serve MAIN.
- Sensor: **imx335, native 2592×1520** (stock 3072×2048 was upscaled).
- Majestic final config: video0 h264 2592×1520@15 4096kbit vbr gop 1s;
  video1 h264 640×360@15 1024kbit; jpeg snapshot on; audio off (HNVR
  ignores audio); OSD off.
- ONVIF: served by Majestic on **port 80** (`/onvif/device_service`),
  HTTP Digest challenge but plain Basic accepted; WSSE digest needs
  cleartext `onvif.username/password` in `/etc/majestic.yaml` (set).
- hnvr integration: cameras row updated via psql (urls, username=root,
  onvif_port=80, probe fields, desired dims); `assigned_host` flipped
  to NULL → coordinator republished → worker restarted on new URL.
  `soapCall` gained an Authorization Basic header (v0.5.0.1) for the
  Majestic digest challenge; leader restart needed to activate.
- Camera kept MAC 00:12:34:39:b4:7a; watchdog on (300 s); NTP not yet
  configured (camera clock free-runs at build time — consider
  `fw_setenv` / Majestic NTP if timestamps ever matter).
