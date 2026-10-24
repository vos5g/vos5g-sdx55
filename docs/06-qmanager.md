# 6. The QManager port

[QManager-GO](https://github.com/evairo176/qmanager) is a modern web UI (a Next.js front end embedded in a Go back end) for **Quectel** modems. It reads everything through Quectel AT commands, which this Compal module doesn't have. The port has two parts:

1. **`qcmd`** (this repo, `qcmd/`), a static Go binary. QManager runs `qcmd "<AT command>"`, and `qcmd` answers in Quectel's format, using:
   * `cricli`, Compal's radio CLI;
   * `atcli`, Compal's AT commands (`AT+BINFO`, `AT+BNRINFO`, `AT+LCAINFO`, `AT+NRCAINFO`, `AT+BCONFIG?`, …);
   * **QMI over QRTR**, through raw `AF_QIPCRTR` sockets with no libqmi (NAS *Get Cell Location Info*), for the neighbour-cell scan.
2. **[qmanager-vos](https://github.com/vos5g/qmanager-vos)**, a fork of QManager-GO with the VOS changes as separate commits on top of upstream (below).

## How `qcmd` behaves

* **Every reply ends in `OK` or `ERROR`,** so QManager never falls back to raw serial access or demo data.
* **Commands are serialised.** A per-command lock plus a short-TTL cache in `/tmp/qcmd-cache` protects the modem's single AT channel. `atcli` can return a stale reply when calls overlap, so each reply is checked against the echoed command and retried.
* **Every write is logged.** Each state-changing command, together with the calling process, goes to `/data/vosclean/log/qcmd-writes.log`.
* **Dangerous commands are refused,** even from the AT terminal: IMEI writes (`AT+EGMR`), factory reset, NV/EFS writes, USB-mode changes and raw SIM access.
* **Anything else matching a safe pattern passes through to the modem.** That makes QManager's AT terminal a real Compal AT terminal.

### Translation table (main commands)

| QManager sends | Answered from |
|---|---|
| `ATI`, `AT+CGMI/CGMM/CGMR`, `AT+CGSN` | `atcli ATI`, `cricli imei` |
| `AT+CPIN?`, `AT+QCCID`, `AT+CIMI`, `AT+CNUM` | `cricli card_status / iccid / imsi / msisdn` |
| `AT+COPS?`, `AT+CREG?/CEREG?/C5GREG?` | `cricli operator / get_registration_state / roaming` |
| `AT+QENG="servingcell"` | `AT+BINFO` / `AT+BNRINFO` + `cricli rat / band / cell_location` |
| `AT+QCAINFO` | `AT+LCAINFO` / `AT+NRCAINFO` |
| `AT+QRSRP` (per-antenna) | per-chain RSRP from `AT+BINFO` / `AT+BNRINFO` |
| `AT+QTEMP` | `/sys/class/thermal` zones |
| `AT+QSCAN` (cell scanner) | QMI NAS 0x0043 over QRTR: serving cell + LTE intra/inter-frequency neighbours |
| `AT+QNWPREFCFG="mode_pref"` / `"lte_band"` / `"nsa_nr5g_band"` / `"nr5g_band"` / `"ue_capability_band"` | `cricli get/set_pref_rat`, `get/set_pref_band`, `band_cap`. "Restore" uses the factory masks saved at install |
| `AT+QNWLOCK="common/4g"` / `"common/5g"` | `cricli set_cell_config` / `set_nr5g_cell_config` |
| `AT+QNWCFG="nr5g_earfcn_lock"` | NR ARFCN lock via `cricli` |
| `AT+CGDCONT`, `AT+CGCONTRDP`, `AT+CGPADDR` | `cricli get/set_profile`, `wwan_config` |
| `AT+QICSGP` (APN username, password, PAP/CHAP) | `cricli get/set_profile`; the password is masked in the write log |
| `AT+CFUN=0/1`, `AT+CFUN=1,1` | `cricli set_op_mode`, `systemctl reboot` |
| `sms_tool` (multi-call) | `cricli` SMS commands. A send that fails on 5G SA is retried on LTE automatically (see 07) |

## What the fork changes in QManager

* **No mock data and no raw serial access on Linux.** Upstream shows fake demo values when it can't reach a modem, and hard-codes several dashboard values (connectivity, LTE category, supported bands). In the fork, the AT client uses `qcmd` only, and those fields show real values or nothing.
* **The connection watchdog recovers on its own** (Monitoring → Watchdog, on by default). It checks the mobile link every few seconds, bypassing any VPN, and after 5 failed checks it restarts the data connection (~6 s), then the radio (~15 s), then the stick (~80 s). It restarts the stick at most once per outage and at most 3 times an hour, and waits 3 minutes after boot. Each step can be switched off on its page. The old watchdog, switched on with `QM_WATCHDOG=1`, caused reboot loops; that variable is no longer used.
* **Alerts and SMS forwarding send for real.** Alerts go out by SMS (connection lost, restored, stick restarted) and by email (restored, restarted) straight over SMTP; use an app password for Gmail, Outlook or iCloud. Forwarding resends each new text to another number. Use **Send test** on either page to check.
* **Data usage** on the dashboard counts the modem's own traffic counters, so offloaded traffic is included. It may differ slightly from your carrier's figure.
* **Self-update is disabled,** because it would replace this build with an upstream one.
* **Settings live under `/data/vosclean/qm`,** because `/etc` is read-only here.
* **Parser fixes** for Quectel reply formats: 5G SA and LTE serving cell, `CGCONTRDP` DNS, CA and band lists.
* **Cellular Information page:** fills in Cell ID, TAC, eNB/sector, NR bandwidth, total bandwidth and carrier details, and IPv4 DNS.
* **The Cell Scanner endpoint returns the shape the page expects,** including PLMN → operator names.
* **Custom DNS is applied for real.** Upstream only saved it to a file; the fork calls `vosclean dns` (see 07).
* **Tailscale works for real.** Upstream's VPN → Tailscale endpoint is a stub that does nothing. The fork implements it, and adds two controls to the page: *Accept subnet routes* and *Use exit node*. See 07.
* **New pages:** NetBird, WireGuard, Kernel Modules, Web Console, System Health Check, bandwidth monitor and a working speed test. See 07.
* **Pages that do nothing on this modem are hidden** (the list and the reasons are in the fork's `src/constants/vos-features.ts`).
* **Audit log.** Every non-GET request is logged to `/data/vosclean/log/qm-requests.log` (method, path and client, never request bodies). If a reboot is ever triggered from the UI, it shows up there.

## Feature matrix on this module

The up-to-date list of what works, and of what is hidden and why, is in the [qmanager-vos README](https://github.com/vos5g/qmanager-vos#what-works).

## Building

QManager is built in [qmanager-vos](https://github.com/vos5g/qmanager-vos#building) (Node 20+ or Bun, Go 1.24+); its CI attaches `qmanager-core-armv7` to each release. `qcmd` is built here with `./qcmd/build.sh`.
