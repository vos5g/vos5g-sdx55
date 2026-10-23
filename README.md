# VOS 5G / SG500M2-X (Snapdragon X55): audit, hardening and a better web UI

This is a reference and step-by-step guide for owners of the **Tri Cascade VOS 5G USB dongle**. It also covers the bare **TRITOM / Tri Cascade SG500M2-X** M.2 module inside it, which is Compal's **RXM-G1** on a Qualcomm SDX55 / X55. It records what was found in the stock firmware and how to back the device up properly. It also gives you a reversible package that:

* **hardens the device:** key-only root SSH, a WWAN-side firewall, the vendor's remote-update client blocked, RPC/NFS off, and stable SSH host keys;
* **installs [QManager-GO](https://github.com/evairo176/qmanager)** as the web UI, ported from Quectel to this Compal module through a small translator (`qcmd`). You get signal and carrier aggregation, band, cell and 5G-ARFCN locks, the APN, SMS, a neighbour-cell scan, custom DNS, Tailscale, NetBird, a WireGuard VPN client, an AT terminal and more;
* **adds optional kernel features** (kernel WireGuard, IPv6 NAT, BBR, fq_codel, extra firewall matches) as modules for the stock kernel, built in the separate [vos5g-kmod](https://github.com/thalatamsainath/vos5g-kmod) repo and switched on and off in QManager;
* **leaves the read-only system partition untouched.** Everything lives in `/data/vosclean`, starts from one line in a vendor boot script, and is removed with one command.

> **Status:** these tools were tested on one unit, firmware `RXMG1.20.00.326.73_0R19` (v73), customer ID 19 (VOS Dongle), on O2 UK. Other carriers and firmware versions should work but haven't been tested. Read [docs/03-backup.md](docs/03-backup.md) and make your backups **before** you install anything.

## Contents

| | |
|---|---|
| [docs/01-device.md](docs/01-device.md) | What the hardware is: identification, specs, partitions, USB modes |
| [docs/02-firmware-findings.md](docs/02-firmware-findings.md) | Firmware integrity and security audit: what is worrying and what isn't |
| [docs/03-backup.md](docs/03-backup.md) | Backups that can actually be restored: QCN (EFS/IMEI) plus UBI volumes. What **not** to read |
| [docs/04-first-access.md](docs/04-first-access.md) | Getting root SSH and adding your key |
| [docs/05-install.md](docs/05-install.md) | Installing vosclean and QManager with `install.sh` |
| [docs/06-qmanager.md](docs/06-qmanager.md) | The QManager port: how `qcmd` works, the feature matrix, building it |
| [docs/07-features-and-limits.md](docs/07-features-and-limits.md) | Custom DNS, cell scan, SMS on 5G SA, band unlocking, dual SIM, video optimiser, … |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | Logs, the kill switch, uninstalling, recovery (fastboot / EDL) |
| [docs/09-router-use.md](docs/09-router-use.md) | Using the dongle with an OpenWrt router, and other UIs |

## Repository layout

```
install.sh              installs/updates everything over SSH from a Mac or Linux PC
vosclean/               the on-device payload (copied to /data/vosclean)
  bin/vosclean            control script: apply | status | qmpass | dns | watch | ...
  bin/boot.sh             boot entry, started from /oem/script/oem_init_post.sh
  bin/dns.sh              custom upstream DNS (iptables DNAT of dnsmasq's queries)
  bin/uninstall.sh        removes the hook and undoes all live changes
  bin/diag.sh             optional reset diagnostics (enabled by /data/vosclean/DIAG)
  etc/vosclean.conf       settings (each feature can be switched off)
  stub/fotaclient         replaces the vendor update client at runtime
  web/                    minimal fallback web UI (disabled by default)
qcmd/                   Go: Quectel-AT -> Compal (cricli / atcli / QMI) translator
qmanager/               vosclean.patch + build.sh against a pinned upstream commit
tools/                  backup-ubi.sh (per-volume backups), build-tailscale-tiny.sh, vos_readonly_probe.sh
```

## Quick start

1. Read [docs/03-backup.md](docs/03-backup.md). Make a QCN backup with QPST and a UBI backup (`tools/backup-ubi.sh`).
2. Build the binaries (or download them from Releases, if available):
   ```bash
   ./qcmd/build.sh          # -> dist/qcmd-armv7         (needs Go 1.22+)
   ./qmanager/build.sh      # -> dist/qmanager-core-armv7 (needs Go + Node 20)
   ```
3. Install:
   ```bash
   ./install.sh --check     # compatibility check only, changes nothing
   ./install.sh --pubkey ~/.ssh/id_ed25519.pub \
                --qmanager dist/qmanager-core-armv7 --qcmd dist/qcmd-armv7
   ssh -t root@192.168.225.1 /data/vosclean/bin/vosclean qmpass   # set the QManager password
   ```
4. Open **http://192.168.225.1:8080**, or **https://192.168.225.1:8443** (self-signed certificate).

To undo: `ssh root@192.168.225.1 /data/vosclean/bin/uninstall.sh`

## Credits and licences

* Prior community work: the [eko.one.pl forum thread on the VOS 5G](https://eko.one.pl/forum/viewtopic.php?id=25031). It covers USB modes, bootloader state, EDL, QCN backup and band policy. Many thanks to its contributors.
* [QManager](https://github.com/dr-dolomite/QManager) by DrDolomite and the [QManager-GO fork](https://github.com/evairo176/qmanager) by evairo176. QManager-GO is licensed **MIT with Commons Clause**. This repository ships only a patch against them, and the same licence applies to the patched result (you may not sell it).
* [luci-app-5gmodem](https://github.com/fildunsky/luci-app-5gmodem): a router-side LuCI app that already supports this module.
* Everything else here (vosclean, qcmd, tools, docs) is MIT; see [LICENSE](LICENSE).

This project isn't affiliated with Tri Cascade, Compal, Qualcomm or any carrier. Modifying your device is at your own risk.
