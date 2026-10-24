# 5. Installing vosclean (+ QManager)

## What gets changed on the modem

| Change | Where | Undo |
|---|---|---|
| Payload | `/data/vosclean/` (scripts, config, logs, saved host keys, QManager) | `rm -rf /data/vosclean` |
| Boot hook: one line appended | `/oem/script/oem_init_post.sh`. The original is saved in `/data/vosclean/backup/` | `uninstall.sh` removes the line |
| `chmod 755` on that script | The vendor ships it non-executable, so systemd's `oeminit_post.service` fails on every boot and the hook would never run. Its own content is harmless: it records the USB mode | — |

Everything else (bind mounts, masked units, iptables rules) is **applied at runtime on each boot**, and nothing is written to the read-only rootfs. If `/data/vosclean/ENABLED` is missing, the hook does nothing at all.

## Build or obtain the binaries

```bash
./qcmd/build.sh        # Go 1.22+ -> dist/qcmd-armv7 (static, about 2.5 MB)
```

QManager (`qmanager-core-armv7`, about 18 MB with the web UI embedded) is built in its own repo, [qmanager-vos](https://github.com/vos5g/qmanager-vos): take it from that repo's Releases, or build it there (see its README). Skip it if you only want the hardening part.

## Install

```bash
./install.sh --check
./install.sh --pubkey ~/.ssh/id_ed25519.pub --qmanager /path/to/qmanager-core-armv7 --qcmd dist/qcmd-armv7
```

The installer:

1. **Checks the device.** It must be ARMv7 and `sdxprairie`, have `cricli` and the vendor hook script, and have more than 40 MB free on `/data`. If any check fails, it stops without changing anything.
2. **Copies the payload.** An existing `etc/vosclean.conf` is **kept**, so re-running the installer is a safe way to update.
3. **Adds your public key.**
4. **Uploads the two binaries** and checks each SHA-256 on the modem before swapping it in.
5. **Installs the hook**, creates `ENABLED` and starts `boot.sh`. About 20 seconds later it applies everything and prints `vosclean status`.

Then:

```bash
ssh root@192.168.225.1 'echo works'                              # key login works?
ssh -t root@192.168.225.1 /data/vosclean/bin/vosclean qmpass     # QManager password (min 10 chars)
```

**Until you set a password, QManager accepts the default `admin`.** Open `http://192.168.225.1:8080` or `https://192.168.225.1:8443`.

## Settings: `/data/vosclean/etc/vosclean.conf`

| Key | Default | Meaning |
|---|---|---|
| `SSH_PASSWORD_AUTH` | `no` | Turns root password login off (only once a key exists) |
| `FIREWALL_WWAN_BLOCK` | `yes` | Drops new inbound connections on `rmnet+`/`ppp+` (v4 and v6) |
| `DISABLE_FOTACLIENT` | `yes` | Stubs `/sbin/fotaclient` and masks its units |
| `DISABLE_RPC_NFS` | `yes` | Stops and masks rpcbind and the NFS units |
| `PERSIST_HOSTKEYS` | `yes` | Keeps the SSH host keys stable across reboots |
| `UI_ENABLE` | `no` | Minimal fallback UI on `https://192.168.225.1:8444` (`vosclean uipass` first) |
| `QM_ENABLE` | `yes` | Runs QManager (systemd transient unit `qmanager`, memory capped at 80 MB) |
| `QM_PORT` / `QM_TLS_PORT` | `8080` / `8443` | QManager ports. The stock UI keeps 80/443 |
| `QM_WATCHDOG` | `0` | No longer used by current QManager builds: the watchdog is set on its page (Monitoring → Watchdog). See [06-qmanager.md](06-qmanager.md) |
| `SSR_RELATED` | `yes` | On a baseband crash, restart only the modem (about 30 s without data) instead of resetting the whole device. `no` restores the firmware default |
| `SSR_RECOVER_SECS` | `180` | After a modem crash, reboot the device anyway if mobile data isn't back within this many seconds |
| `HEARTBEAT_MINUTES` | `5` | How often the on-flash flight recorder (`log/heartbeat.log`) gets a line |
| `MODULES` | (empty) | Extra kernel module groups to load (`wireguard ipv6nat bbr fqcodel xtmatch`); see [features](07-features-and-limits.md#extra-kernel-modules). Build with [vos5g-kmod](https://github.com/vos5g/vos5g-kmod), upload with `install.sh --modules`; QManager → Kernel Modules edits this line |

After editing, run `/data/vosclean/bin/vosclean apply`.

## Day-to-day commands (on the modem)

```sh
vosclean status     # what is active
vosclean apply      # re-apply everything (idempotent)
vosclean qmpass     # set the QManager password
vosclean dns        # re-apply custom DNS from etc/dns.conf (QManager writes this file)
vosclean fw | stop-fw
uninstall.sh        # remove the hook and undo the live changes (files kept)
```

Every minute, `boot.sh` re-checks the firewall jump, the DNS and Tailscale rules (QCMAP can flush them) and the modem crash counter. Every `HEARTBEAT_MINUTES` it appends a line (uptime, free memory, load, QManager RSS, modem crashes, lowest supply voltage since the last line) to `log/heartbeat.log` on flash, and each boot logs the PMIC's power-on reason (e.g. `power-dip(SMPL)`) to `log/vosclean.log`, so an unexpected reset leaves evidence.

**Logs and flash wear.** To spare the NAND, the busy logs live in RAM:
* **QManager's output** goes to `/tmp/vosclean/log/qmanager.log`, capped at 512 KB.
* **On a clean shutdown,** the last 300 lines of each RAM log are saved to `log/last-boot/`.
* **What stays on flash** is the event and audit logs, all small and capped: `vosclean.log`, `heartbeat.log`, `modem-crashes.log`, `qm-requests.log` (max 2 × 256 KB) and `qcmd-writes.log` (max 2 × 200 KB). QManager's own live data (signal and ping history, status) is in `/tmp`.
