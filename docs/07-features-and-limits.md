# 7. Features and limits, in detail

## Custom DNS

Every device on the USB link gets `192.168.225.1` (the modem's dnsmasq) as its DNS server. dnsmasq forwards queries to the operator's servers listed in `/etc/resolv.conf`, which QCMAP manages.

`vosclean dns` (`bin/dns.sh`) leaves dnsmasq alone. Instead it **DNATs dnsmasq's upstream queries** in `iptables -t nat OUTPUT` (chain `VOS_DNS`):

* operator server 1 → your server 1, operator server 2 → your server 2, and so on (so dnsmasq's failover still works);
* a catch-all for any other port-53 traffic leaving on `rmnet+` → your server 1.

Saving the DNS card in QManager writes `/data/vosclean/etc/dns.conf` (`DNS_ENABLE`, `DNS_SERVERS`), then runs `vosclean dns`. The watch loop re-applies the rules within a minute if QCMAP flushes the nat table or the operator hands out new servers. Disabling the feature removes the chain.

To check that it works, from the computer:

```bash
dig +short TXT o-o.myaddr.l.google.com @192.168.225.1   # shows the resolver's egress address: operator's vs e.g. Cloudflare's
ssh root@192.168.225.1 'conntrack -L -p udp --dport 53 | head'   # replies come back from your chosen server
```

Limits:
* **IPv4 only.**
* **Some devices skip the modem's DNS altogether:** clients with a hard-coded DNS server, DNS-over-HTTPS in a browser, or iCloud Private Relay. Their queries never go through the modem's dnsmasq, and with hardware offload they are invisible to Linux.

## Cell scanner (neighbour cells)

* **There is no Quectel-style `AT+QSCAN`, which would sweep all bands for all operators.** The scan shows what the modem is already measuring: the **serving cell plus LTE intra- and inter-frequency neighbours of your own carrier**. It reads them over QMI NAS (*Get Cell Location Info*, message 0x0043).
* **On 5G SA, only the NR serving cell appears,** because the modem doesn't report NR neighbours. For a fuller list, switch the network mode to LTE, scan, then switch back.
* **It needs a SIM,** unlike on Quectel modules, where the hint says to scan without one.

## SMS on 5G standalone

Some networks (O2 UK, for one) don't carry SMS for this module while it is attached in **NR5G-SA**. `cricli` then fails with rc 21.

* **Sending:** `qcmd`'s `sms_tool send` detects this, switches to LTE, sends, and restores your network mode. This takes about 15 seconds.
* **Receiving:** texts may not arrive while the modem stays on SA.

## Band "unlocking"

The forum's band unlock edits `/policyman/carrier_policy.xml` in EFS with QPST EFS Explorer, cutting its `<select>` down to `<rf_bands base="hardware"/>`. It unblocked n41 on a Polish network, and a factory reset from the stock web UI reverts it.

* **No v73 carrier bundle contains a `carrier_policy.xml`.** The only band policy in them, `generic_band_restrictions.xml`, restricts US and Singapore networks. So whether your unit has a restrictive policy depends on what was written at the factory.
* **Check what your modem allows first:** `cricli get_pref_band` versus `cricli band_cap`. On the test unit, the preferences already matched the hardware capability.
* **Back up `/policyman` before editing it.**

## Two SIMs?

**No, not on the VOS dongle.** The adapter board has one SIM holder, and the modem reports one physical slot. The module does carry dual-SIM profiles, and the M.2 connector has SIM2 pins. A different carrier board plus a low-level profile switch might enable a second SIM (single-standby, so one active at a time). That is untested and changes NV configuration.

## Video optimiser / DPI masquerade (zapret / nfqws)

**This can't work on the modem in its normal mode.** USB↔cellular traffic goes through the **IPA hardware accelerator**, which does the NAT in hardware. Measured: zero forwarded packets reached Linux while the host was streaming. So `nfqws` never sees user traffic.

The only workaround is to turn off IPA offload and route everything through the 1.5 GHz Cortex-A7. That cuts 5G throughput to around 100 Mb/s or less. **If you need DPI evasion, run zapret on the host or on an OpenWrt router.**

## LTE EARFCN-only lock, NR-DC

* **LTE EARFCN-only lock: not supported.** The modem only locks LTE to an EARFCN together with a PCI (a cell lock, which works).
* **NR-DC / mmWave: not supported.** The module reports `MMW_RFC_ID: 0`, meaning no mmWave RF.

## Unexplained reboots

The test unit occasionally rebooted by itself (about 3 times in 3 hours during development). Memory and load were normal, and no reboot command was logged by `qcmd` or QManager. Here is what is known so far:

* **These are warm resets, not power loss.** After such a reboot, the clock reads "1970 + about 10 minutes" before NITZ fixes it, so the PMIC RTC kept running. After a real unplug it restarts from 0. (The stick does draw a lot of power, so still use a good port.)
* **A baseband crash restarts the whole device.** On this firmware, the modem and IPA subsystems are set to `restart_level=SYSTEM`, and the kernel reboots 5 s after a panic or oops (`kernel.panic=5`, `panic_on_oops=1`). pstore is disabled, so no reason survives the reboot.
* **The cause is not traced to vosclean or QManager.**

**Diagnostics mode** (`touch /data/vosclean/DIAG`, then reboot; `rm` the file to turn it off) starts `bin/diag.sh` early in each boot. It:
* sets the modem subsystem to `restart_level=RELATED`, so a baseband crash restarts only the modem (about 30 s without data) and shows up in `crash_count` and the kernel log, instead of rebooting the device;
* writes the PMIC power-on / reset-reason registers for each boot to `log/diag/pon-<boot>.txt`;
* copies the kernel log (`/dev/kmsg`) and the error lines from `/var/log/messages` to `log/diag/`, syncing every 3 s, so the last messages before a reset survive.

If the device still resets with diagnostics on, and the kernel log just stops with no panic, suspect power. Many router USB ports can't supply the current the stick draws under 5G load; try a powered USB 3 hub.

Evidence collected on every boot:

* `log/heartbeat.log`: one line a minute; a `--- boot` line marks each new boot;
* `log/vosclean.log`: "previous boot's last heartbeat";
* `log/qcmd-writes.log` and `log/qm-requests.log`: every write or command, and every UI action.

If you see reboots too, please open an issue with those logs (redact your IMEI and phone number).
