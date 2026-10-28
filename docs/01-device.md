# 1. The device

## What it is

| | |
|---|---|
| Retail product | **Tri Cascade VOS 5G** USB dongle: an M.2 module on an M.2-to-USB 3 adapter board |
| Module | **TRITOM / Tri Cascade SG500M2-X**: Compal project **RXM-G1**, board codename `zx56` |
| Chipset | Qualcomm **Snapdragon X55** (SDX55, Linux platform name `sdxprairie`) |
| Application CPU | 1 × ARM Cortex-A7 (ARMv7) at up to 1.55 GHz, about 222 MiB RAM visible to Linux |
| Flash | 512 MiB NAND (Micron MT29F4G08ABBFA3W), 26 MTD partitions, UBI/UBIFS |
| OS | Qualcomm LE (Yocto) Linux, kernel `4.14.117-perf`, systemd, SELinux (permissive) |
| Firmware examined | `RXMG1.20.00.326.73_0R19` ("v73"), build branch `sdx55-release-LE1.2-post-CS13-M2-Tricascade-VOS` |
| Management address | `192.168.225.1` on the USB network (DHCP hands out `.20`–`.60`) |
| Stock web UI | ports 80/443, default login `admin` / `admin` |

Some notes on the names:

* **The "M" on the label is part of the model name.** In "SG500**M**2-X", M2 is the form factor; it isn't a different vendor.
* **TRITOM is Tri Cascade's brand.** The firmware sets the USB manufacturer to "Tri Cascade Inc." and the product to "SG500M2-X" or "VOS_5G", depending on a customer ID stored in `/oem`. That ID is 08 for the bare module, 19 for the VOS Dongle, 21 for VOS AT&T and 23 for VOS Google. Linksys and APAL variants of the RXM-G1 exist too.
* **The newer Tri Cascade VOSIO X62 is a different device.** It uses a **Quectel** RG520N, which is why Quectel tools fit it but not this one.

## Software you will meet on the device

| Tool | What it is |
|---|---|
| `cricli` | Compal's radio CLI. Signal, bands, cell locks, SMS, profiles, QCMAP (NAT/LAN) and more. Run it with no arguments for the full list |
| `atcli "AT..."` | Sends an AT command to the modem. Compal's info commands are `AT+BINFO` (LTE), `AT+BNRINFO` (NR), `AT+LCAINFO` / `AT+NRCAINFO` (CA) and `AT+BCONFIG?` (band masks). `AT+CLAC` lists everything |
| `QCMAP_ConnectionManager`, `ipacm` | Qualcomm's router stack. It owns iptables/NAT and dnsmasq, and can rewrite them at any time |
| `/sbin/fotaclient` | Vendor update client. See [02-firmware-findings.md](02-firmware-findings.md) |
| `/oem/script/oem_init_post.sh` | Vendor late-boot script that runs from `/oem` (writable). vosclean hooks in here |

**Important: Quectel AT commands do not exist on this modem.** Commands like `AT+QENG`, `AT+QCAINFO` and `AT+QNWPREFCFG` aren't there. That is why Quectel-oriented UIs (Simple Admin, QManager) show empty pages until a translator like `qcmd` is added.

## Storage layout

| Mount | Backing | Writable? | Notes |
|---|---|---|---|
| `/` | `ubi0:rootfs` (mtd25 `system`) | **read-only** | Vendor OTA patches check the hashes of these files: don't change them |
| `/data` | `ubi0:usrfs` | yes, about 107 MiB | vosclean lives in `/data/vosclean` |
| `/systemrw` | `ubi0:systemrw` | yes | Backs many `/etc/data/*` files and `/etc/passwd`/`shadow` (bind mounts) |
| `/persist`, `/cache` | `ubi0:persist`, `ubi0:cachefs` | yes | |
| `/oem` | `ubi2:oemfs` (mtd24 `oem`) | yes, about 31 MiB | Vendor web UI and scripts. **Upper dirs of the overlays on `/bin`, `/usr`, `/lib`** |
| `/firmware` | `ubi1:modem` (mtd17) | ro | Baseband firmware |

The MTD map is: `sbl, mibib, efs2, tz, tz_devcfg, ddr, apdp, xbl_config, multi_image, aop, qhee, abl, uefi, toolsfv, loader_sti, boot, scrub, modem, misc, devinfo, recovery, fota, recoveryfs, sec, oem, system`.

> **Never read `efs2` (mtd2) from Linux.** It sits in a TrustZone-secured range (offset `0x500000`, size `0xb00000`, the same as Qualcomm's SDX55 reference boards), and reading it **resets the modem**. Back EFS up as a QCN instead ([03-backup.md](03-backup.md)). `ddr` (mtd5) carries the same partition attribute; leave it alone too.

## USB modes

The USB composition is chosen at boot from `/etc/usb/boot_hsusb_comp`. Query it with `atcli 'AT+USBCOMP?'`.

| PID (VID 05c6) | Mode | Notes |
|---|---|---|
| **9063** | "user" | **Factory default.** ECM network to the host, data path offloaded in hardware (IPA) |
| **9064** | QMI + DIAG + ADB + AT, plus ECM and MBIM configurations | QMI for Linux/OpenWrt, ECM for macOS, MBIM for Windows; host selects configuration |
| 9165 | ECM + DIAG + ADB + AT serial | Best for development. Internet still works |
| 9091 | QMI (rmnet) | Used by ModemManager / luci-app-5gmodem. Reported unstable with multiplexing on |
| 905B | MBIM only | Getting out of it needs Windows: `ATcommandCLI.exe "at+usbcomp=rndis"` from Switch_Tool |
| 04b7:9058 | Switch_Tool's RNDIS | Reported to hang on disconnect |

To change mode: `echo 9165 > /etc/usb/boot_hsusb_comp`, then reboot, or `AT+USBCOMP=rndis`. **QPST/QFIL need the DIAG port**, which needs an RNDIS/DIAG composition (Switch_Tool can do it). The mode table comes from the eko.one.pl thread.

## Bootloader and recovery state

These points come from the eko.one.pl thread and are consistent with this unit's `devinfo` bytes and ABL strings.

* **Fastboot works and the bootloader is unlocked.** `fastboot oem device-info` reports `Device unlocked: true` and `Device critical unlocked: true`. `fastboot getvar all` reports `secure:no`. Flashing a large image needs `-S 256M`.
* **EDL (9008) is reachable through test points.** B. Kerler's [`edl`](https://github.com/bkerler/edl) tool then works with a Quectel RG502 loader, so no Compal-signed programmer is needed.
* **Raw partition dumps of `system` failed to restore.** EDL, QFIL and fastboot don't skip NAND bad blocks, so the restores failed with ECC/CRC errors. Use per-volume UBI backups ([03-backup.md](03-backup.md)).
* **OTA packages and recovery are unsigned.** The recovery userspace is older (Jan 2023) than the main system.
