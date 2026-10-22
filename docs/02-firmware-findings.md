# 2. Firmware audit: findings

This audit asked a simple question: *"is anything worrying going on in this modem?"* It worked offline against a full filesystem archive of a live unit, the vendor's v73 OTA package and the Windows updater (`VOS_Dongle_Upgrade_v73.exe`). It also took live process, socket and firewall snapshots.

## Verdict

**There is no sign of implanted or tampered software.** The firmware matches Compal's v73 release. The real problems are **design weaknesses in the vendor's update client** and **factory-default credentials**.

## Integrity

* **The OTA patch targets match.** 447 of the 449 targets match the v73 target hash exactly, and no file has an unknown hash. The two exceptions hold the vendor's own earlier content: `etc/data/miniupnpd/miniupnpd.conf` (preserved config) and `etc/shadow` (bind-mounted from `/systemrw`).
* **Of the 23 complete files in the OTA, only `etc/data/ril.conf` differs,** and only by two log-level lines.
* **Nothing extra is installed.** The overlays on `/bin`, `/usr` and `/lib` are empty apart from vendor placeholders. There are no unexpected executables, UID-0 accounts, `authorized_keys`, cron jobs or setuid binaries.
* **The vendor daemons stay local.** `ceiril`, `ceisar`, `ceiled`, `ceioptimize`, `datasync` and `crid` are QMI/IPC helpers with no outbound networking.
* **The signatures check out.** The Windows updater's Authenticode signature (COMPAL ELECTRONICS, INC.) verifies, and 26 of the 27 modem image segments match their signed SHA-384 table. The remaining segment is the hash/signature segment itself.

## Findings, most significant first

1. **The update path is unauthenticated from end to end.**
   * `fotaclient` fetches update metadata over plain HTTP. Its HTTPS code sets `CURLOPT_SSL_VERIFYPEER=0`.
   * Packages get only an optional MD5 check, fetched from the same server.
   * OTA ZIPs are unsigned, and the recovery binary has no package-verification code.
   * **Whoever answers the update URL can install arbitrary root-level software.**
2. **The fallback update host is on a personal domain.**
   * The primary host, `5gfota.sdbg.compal.com`, no longer resolves.
   * The client then falls back to `http://mifiasdfadkj5pdj.jacky.idv.tw/5g/`. That subdomain doesn't exist today, but its parent domain is registered and live.
3. **The update server can trigger log uploads.**
   * Server "meta-commands" make the client tar logs and PUT them to Amazon S3 buckets, using **long-term AWS access keys hard-coded in the binary**. (The keys are not reproduced here and were never used.)
   * Requests carry the serial number, firmware version, country and time zone.
   * The client can bring up its own cellular data session to do this.
4. **Automatic update checks are off by default.**
   * The timer points to a file that doesn't exist.
   * The client runs only from the web UI's "check for update" button or the `AT+CFOTA` command, which can also enable the timer.
5. **Default credentials, and nothing filtering them.**
   * Root uses Qualcomm's stock password; see [04-first-access.md](04-first-access.md).
   * The web UI login is `admin`/`admin`.
   * sshd allows root login with a password on all interfaces, the INPUT policy is ACCEPT, and SELinux is permissive.
   * `rpcbind` listens on port 111 on all interfaces.
6. **Exposure depends on the mode.**
   * In the default mode, the Linux side has no WWAN address, so these services face only the USB host.
   * When QCMAP backhaul is up (router mode, or during an update check), nothing on the device filters them.
7. **Other outbound-capable services, which are normal Qualcomm components:**
   * `xtra-daemon` (GNSS assistance from `izatcloud.net`). Its crowd-sourced upload, `GTP_MODE`, is disabled.
   * A dormant Verizon carrier-management (motive.com) configuration.

## What vosclean does about it

| Finding | vosclean action (all reversible, rootfs untouched) |
|---|---|
| 1–4 | Bind-mounts a stub over `/sbin/fotaclient` (each call is logged and exits) and masks its timer and units for the boot. The real binary stays on the read-only rootfs underneath |
| 5 | Key-only root SSH (`PasswordAuthentication no`; refused until a key is present), persistent host keys, RPC/NFS stopped and masked |
| 6 | An INPUT chain that drops new connections arriving on `rmnet+` / `ppp+` (IPv4 and IPv6). It is re-inserted if QCMAP flushes INPUT |
| web UI | Not changed: change the `admin` password in the stock UI yourself, or stop using it in favour of QManager |

**Removing `fotaclient` for good** would mean rebuilding the system UBIFS volume without it, then writing it back with `ubiupdatevol` from a working backup. That isn't done here.

## Not established

* What the baseband DSP firmware does internally.
* Whether the carrier can reach the device from the network side.
* Whether `jacky.idv.tw` belongs to Compal.
* Whether any upload happened before the unit's `/data` was last reset.
