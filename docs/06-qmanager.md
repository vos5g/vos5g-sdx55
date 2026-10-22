# 6. The QManager port

[QManager-GO](https://github.com/evairo176/qmanager) is a modern web UI (a Next.js front end embedded in a Go back end) for **Quectel** modems. It reads everything through Quectel AT commands, which this Compal module doesn't have. The port has two parts:

1. **`qcmd`** (this repo, `qcmd/`), a static Go binary. QManager runs `qcmd "<AT command>"`, and `qcmd` answers in Quectel's format, using:
   * `cricli`, Compal's radio CLI;
   * `atcli`, Compal's AT commands (`AT+BINFO`, `AT+BNRINFO`, `AT+LCAINFO`, `AT+NRCAINFO`, `AT+BCONFIG?`, …);
   * **QMI over QRTR**, through raw `AF_QIPCRTR` sockets with no libqmi (NAS *Get Cell Location Info*), for the neighbour-cell scan.
2. **`qmanager/vosclean.patch`**, small changes to QManager itself (below).

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
| `AT+CFUN=0/1`, `AT+CFUN=1,1` | `cricli set_op_mode`, `systemctl reboot` |
| `sms_tool` (multi-call) | `cricli` SMS commands. A send that fails on 5G SA is retried on LTE automatically (see 07) |

## What `vosclean.patch` changes in QManager

* **No mock data and no raw serial access on Linux.** Upstream shows fake demo values when it can't reach a modem, and hard-codes several dashboard values (connectivity, LTE category, supported bands). With the patch, the AT client uses `qcmd` only, and those fields show real values or nothing.
* **The watchdog's recovery actions are off by default.** It still pings, so the latency graphs are real, but radio toggles and reboots only happen with `QM_WATCHDOG=1`.
* **Self-update is disabled,** because it would replace the patched build.
* **Settings live under `/data/vosclean/qm`,** because `/etc` is read-only here.
* **Parser fixes** for Quectel reply formats: 5G SA and LTE serving cell, `CGCONTRDP` DNS, CA and band lists.
* **Cellular Information page:** fills in Cell ID, TAC, eNB/sector, NR bandwidth, total bandwidth and carrier details, and IPv4 DNS.
* **The Cell Scanner endpoint returns the shape the page expects,** including PLMN → operator names.
* **Custom DNS is applied for real.** Upstream only saved it to a file; the patch calls `vosclean dns` (see 07).
* **Tailscale works for real.** Upstream's VPN → Tailscale endpoint is a stub that does nothing. The patch implements it, and adds two controls to the page: *Accept subnet routes* and *Use exit node*. This is the only front-end change. See 07.
* **Audit log.** Every non-GET request is logged to `/data/vosclean/log/qm-requests.log` (method, path and client, never request bodies). If a reboot is ever triggered from the UI, it shows up there.

## Feature matrix on this module

| Page / feature | Status |
|---|---|
| Dashboard, signal, per-antenna, CA, temperatures, latency | ✅ |
| Network mode, LTE / NSA / SA band locking, restore defaults | ✅ |
| LTE cell lock, 5G cell lock, **5G ARFCN lock** | ✅ |
| LTE EARFCN-only lock | ❌ The modem only accepts LTE locks to a specific cell |
| APN / profiles | ✅ |
| SMS inbox / send / delete | ✅ (sending on 5G SA: see 07) |
| Cell scanner | ✅ Your carrier only. LTE neighbours; NR shows the serving cell only |
| Custom DNS (IPv4) | ✅ Applied through dnsmasq upstream DNAT |
| Tailscale (Official and Tiny) | ✅ Install, log in, connect/disconnect, start on boot, accept subnet routes, use/advertise exit node, uninstall |
| AT terminal | ✅ With the dangerous commands blocked |
| Radio off/on, reboot | ✅ |
| SIM slot switching / dual SIM | ❌ One physical SIM slot on the VOS board |
| NR-DC / mmWave | ❌ The module has no mmWave RF |
| IMEI editing | ❌ Deliberately disabled |
| Video optimiser / DPI masquerade | ❌ User traffic is offloaded in hardware (IPA) and never reaches Linux. See 07 |
| QManager self-update | ❌ Disabled (it would drop the patch) |

## Building

```bash
./qmanager/build.sh            # full build
SKIP_WEB=1 ./qmanager/build.sh # back end only (reuses the existing web/out in build/qmanager-src)
```

To move to a newer upstream: update `UPSTREAM_COMMIT`, rebuild, fix any rejects in the patch, run `go test ./...` in `backend/`, then regenerate the patch with `git diff > ../../qmanager/vosclean.patch`.
