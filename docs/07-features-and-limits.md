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

## Tailscale

The VPN → Tailscale page installs and manages Tailscale on the stick itself. You can then reach QManager (`http://<tailscale-ip>:8080`) and SSH on the stick from anywhere in your tailnet. With **exit node** turned on, other devices can send their internet traffic out through the stick's 5G connection.

| Variant | What it is | Space on `/data` |
|---|---|---|
| **Official** | QManager downloads Tailscale's static ARM tarball from pkgs.tailscale.com, checks its published SHA-256, and unpacks `tailscale` and `tailscaled` | about 47 MB |
| **Tiny** (recommended) | One binary (`tailscaled` with the CLI built in), built from Tailscale's own source by `tools/build-tailscale-tiny.sh`, without the features the stick doesn't use. Upload it with `install.sh --tailscale-tiny dist/tailscaled-tiny-armv7`, then press Install → Tiny | about 15 MB |

**What QManager does, and why:**
* **QManager does the download itself.** The stick's busybox `wget` can't do modern TLS, so QManager handles it with Go's HTTP client.
* **It runs `tailscaled` as a systemd unit** (memory capped at 90 MB) in **kernel TUN** mode (`tailscale0`) and with log upload turned off (`--no-logs-no-support`). Tailscale's own iptables handling is off (`--netfilter-mode=off`), because QCMAP owns iptables on this firmware. Tailscale doesn't touch the stick's DNS (`--accept-dns=false`). The device registers in your tailnet as `vos5g`.
* **Connect shows a login link** while the device waits for approval.
* **Login state lives in `/data/vosclean/tailscale/state`.** It survives reboots and switching between the Official and Tiny builds.
* **On boot, vosclean starts `tailscaled`** if "start on boot" is on.
* **Its memory use is modest:** about 17 MB on the test unit.

**Subnet routes and exit nodes** (switches on the same page):
* **Accept subnet routes** lets the stick use networks that other tailnet devices share, for example a router advertising your home LAN with a NAS on it. It works for the stick itself and for devices connected through it, such as a laptop or a GL.iNet router behind the stick. Traffic to those subnets isn't part of the 5G hardware fast path: Linux on the stick routes it into `tailscale0`. vosclean adds a MASQUERADE rule and TCP MSS clamping for that (`vosclean tsfw`, re-applied by the watch loop). Tested: DNS over TCP to a home router at `10.0.0.1` from a laptop behind a GL.iNet behind the stick.
  * **A ping test can mislead you.** With routes off, a private address such as `10.0.0.1` may still answer *from the carrier's own network* (O2 does). Test a real service, not ping.
* **Use exit node** sends internet traffic out through another device in your tailnet: the stick's own traffic **and** the traffic of devices connected through it. Tested: with a home server as exit node, a laptop behind a GL.iNet behind the stick showed the server's public IP, and DNS kept working. While an exit node is active, that traffic goes through Linux and WireGuard in software on the Cortex-A7 instead of the 5G hardware fast path, so expect much lower speeds. Turn it off for full 5G speed.
  * **Measured on the test unit** (5G baseline about 83 Mbit/s at the time): about 17–18 Mbit/s through an exit node with a direct connection, and less through a DERP relay or an exit node with a slow uplink. Throughput is CPU-bound: `tailscaled` uses the whole Cortex-A7, because Go's ChaCha20-Poly1305 has no ARMv7 assembly and the 4.14 kernel has no in-kernel WireGuard. GC tuning (`GOGC=200`, `GOMEMLIMIT=60MiB`, now the default) gains about 5%. For full speed, run the Tailscale client with an exit node on the device itself (laptop or phone) and leave the stick's exit node at None.
  * **Tiny builds before this fix leave the list empty.** They lacked the `useexitnode`/`useroutes` features, so no exit nodes showed up. `tools/build-tailscale-tiny.sh` now includes them.
* **Advertise as exit node** offers the stick itself as an exit node to the rest of your tailnet. Approve it in the Tailscale admin console.
* **Reconnecting keeps these settings:** "Connect" re-runs `tailscale up --reset` with them restated.

**Tiny leaves out:** Tailscale SSH (use the stick's normal sshd over the tailnet), Taildrop, Serve/Funnel, MagicDNS handling, iptables management and log upload. It keeps routing, NAT traversal, port mapping, exit node and subnet advertising, health reporting and the CLI. Community "tiny" builds for GL.iNet routers also exist (for example admonstrator/glinet-tailscale-updater). Those are UPX-compressed third-party binaries without published checksums, so they're not used here.

## NetBird

The VPN → NetBird page installs NetBird's official ARM build (`linux_armv6`, about 15 MB download, 40 MB on `/data`). It verifies the release checksum and runs the daemon as the `netbird` unit, with its state in `/data/vosclean/netbird/state`. **Connecting needs a setup key**, created in the NetBird dashboard; browser login can't be completed from the modem. NetBird's DNS management is turned off, because it would rewrite the stick's own resolver. The daemon uses about 20–26 MB of RAM.

**Only one of Tailscale and NetBird can be installed.** Both use 100.64.0.0/10, so the pages and the backend refuse to install the second one. Start on boot works like Tailscale's (`ENABLED_ON_BOOT`, started by `vosclean apply`). The watch loop also adds NAT and MSS clamping on `wt0`, so devices behind the stick can reach NetBird routes.

## Extra kernel modules

The stick's kernel (4.14.117-perf) loads unsigned modules, so features it was built without can be added without touching the signed boot chain. The [vos5g-kmod](https://github.com/thalatamsainath/vos5g-kmod) repo builds them from Qualcomm's public SDX55 kernel on CodeLinaro (`LE.UM.4.4.2.r1-01400-SDX55`, the last SDX55 release still on 4.14.117), configured with the stick's own `/proc/config.gz`. Compal's own kernel changes aren't public. The script refuses to build if any built-in option would change, because a module compiled against a different structure layout than the running kernel would crash it.

| Group (`MODULES=`) | Modules | What it gives |
|---|---|---|
| `wireguard` | udp_tunnel, ip6_udp_tunnel, wireguard (compat 1.0.20220627) | Kernel WireGuard. NetBird uses it when present; Tailscale never does |
| `ipv6nat` | nf_nat_ipv6, nf_nat_masquerade_ipv6, ip6table_nat, ip6t_MASQUERADE | IPv6 NAT, masquerade and DNAT (e.g. IPv6 DNS redirection) |
| `bbr` | tcp_bbr, sch_fq | BBR for the stick's own TCP connections (set as the default when loaded) |
| `fqcodel` | sch_fq_codel | fq_codel queueing for traffic the CPU routes |
| `xtmatch` | xt_owner, xt_string (+ ts_bm, ts_fsm), xt_connbytes | Extra iptables matches |

All 15 modules were loaded, used (real iptables/ip6tables rules, a WireGuard tunnel, fq_codel on an interface) and unloaded on the stick with no kernel warnings. Everything is 250 KB on `/data`. Build them there (or take a release tarball), upload with `install.sh --modules /path/to/vos5g-kmod/dist/modules-4.14.117-perf`, then switch groups on in **QManager → System Settings → Kernel Modules** (or set `MODULES` in `etc/vosclean.conf` and run `vosclean modules`). Enabled groups load at every boot; switching one off unloads it unless it is still in use. If the stick crashes or resets while modules are loading, the next boot skips them and `vosclean status` says so, until `vosclean modules` is run by hand. Unloading needs a reboot (remove the group first).

**Kernel vs userspace WireGuard, measured on the stick** (tunnel to a fast peer over USB, two runs each):

| | Kernel module | wireguard-go (userspace) |
|---|---|---|
| Stick encrypts (sends into the tunnel) | about 114 Mbit/s | about 36 Mbit/s |
| Stick decrypts (receives from the tunnel) | about 25–30 Mbit/s | about 48 Mbit/s |

The kernel path is about three times faster when the stick sends, for example when it is an exit node serving downloads to remote peers. It is slower when the stick receives, for example when a device behind it downloads from a NAS over the tunnel; that path is CPU-bound in the single core's receive processing, and a larger network budget did not help. There is no NEON in kernel mode (`KERNEL_MODE_NEON` is off), so the module uses the scalar ARM cipher code.

**Not possible as modules:**
* **nftables:** `CONFIG_NF_TABLES` adds a member to `struct net`.
* **eBPF, kprobes, ftrace:** built in or nothing.
* **pstore/ramoops crash logs:** these need reserved memory in the signed device tree.

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

## TTL / hop limit

**Not possible on the stick, for the same reason.** The kernel has the `TTL` and `HL` targets, but a test rule (`iptables -t mangle … -o rmnet_data+ -j TTL --ttl-set 65`) matched 22 packets during a 20 MB upload of about 14,000 packets. Only the first packets of each connection reach Linux; IPA forwards the rest. Rewriting just those would make TTLs inconsistent, which is easier to detect than leaving them alone. QManager's TTL card says so and applies nothing.

**Set TTL on the router in front of the stick instead**, on its interface towards the stick (OpenWrt fw4: `ip ttl set 65` / `ip6 hoplimit set 65` in a postrouting chain; older iptables: `-j TTL --ttl-set 65` and `-j HL --hl-set 65`). Whether IPA itself lowers TTL can't be checked from the stick.

## Live traffic and data counters

`/proc/net/dev` misses almost everything for the same reason (a 40 MB download added under 1 KB to `rmnet_data0`). QCMAP keeps per-call counters that include offloaded traffic: `cricli wwan_stats` (IPv4/IPv6 TX/RX bytes, about 10 ms per call). QManager's live traffic uses these, over an authenticated WebSocket on the main port (upstream ran an open listener on port 8838; that is gone). Measured: 236–263 Mbit/s during a download.

## Speed test

QManager tests against real speedtest.net servers in pure Go. The test runs **on the stick**, whose single Cortex-A7 core (about 1.1 GHz under load) caps it at roughly 50–100 Mbit/s. Devices behind the stick use the IPA fast path and can be much faster (about 180–260 Mbit/s measured with plain downloads). Some servers, including O2's own, refuse HTTP uploads; QManager then measures upload over Ookla's TCP protocol.

## Web console and health check

* **Web console** (System Settings → Web Console): a root shell in the browser. QManager opens the PTY itself, so no ttyd is needed. It is off by default and needs a logged-in session from the same origin. It closes on logout, after 30 idle minutes, or as soon as it is switched off. At most two can be open at once, and every open, close and toggle goes to `log/qm-requests.log`.
* **System health check**: 34 read-only checks, such as flash wear (UBI erase counts), recent flash writes, modem crash handling, hardening, the IPA fast path, DNS, Tailscale and unexpected resets. It also builds a support bundle, with IMEI, ICCID, IMSI, phone number, public IPs and e-mail addresses replaced. Cell IDs and the carrier-NAT WAN address are kept.

## LTE EARFCN-only lock, NR-DC

* **LTE EARFCN-only lock: not supported.** The modem only locks LTE to an EARFCN together with a PCI (a cell lock, which works).
* **NR-DC / mmWave: not supported.** The module reports `MMW_RFC_ID: 0`, meaning no mmWave RF.

## Unexplained reboots

**Most likely, it's power.** On a router's USB port the test unit reset every few minutes, and it stopped completely with a separate power feed (see [09-router-use.md](09-router-use.md)). On a Mac it reset about once an hour during heavy use.

The test unit occasionally rebooted by itself (about 3 times in 3 hours during development). Memory and load were normal, and no reboot command was logged by `qcmd` or QManager. Here is what is known so far:

* **These are warm resets, not power loss.** After such a reboot, the clock reads "1970 + about 10 minutes" before NITZ fixes it, so the PMIC RTC kept running. After a real unplug it restarts from 0. (The stick does draw a lot of power, so still use a good port.)
* **A baseband crash restarts the whole device.** On this firmware, the modem and IPA subsystems are set to `restart_level=SYSTEM`, and the kernel reboots 5 s after a panic or oops (`kernel.panic=5`, `panic_on_oops=1`). pstore is disabled, so no reason survives the reboot.
* **The cause is not traced to vosclean or QManager.**

**Modem crashes no longer reset the device (vosclean default).** vosclean sets the modem subsystem to `restart_level=RELATED` at boot.
* **What a baseband crash now does:** it restarts only the modem, so you're without data for about 30 s while Linux keeps running.
* **Each crash is recorded:** the watch loop writes the crash count and the related kernel lines to `log/modem-crashes.log`.
* **Fallback:** if mobile data isn't back after `SSR_RECOVER_SECS` (180 s), vosclean reboots the device cleanly. It doesn't do this if the radio was switched off on purpose.
* **To go back to the firmware default,** set `SSR_RELATED=no`.

**Diagnostics mode** (`touch /data/vosclean/DIAG`, then reboot; delete the file to turn it off) starts `bin/diag.sh` early in each boot. It:
* copies the kernel log and the error lines from `/var/log/messages` to `log/diag/`, syncing every 3 s, so the last messages before a reset survive;
* writes the PMIC power-on / reset-reason registers for each boot to `log/diag/pon-<boot>.txt`.

Leave it off normally: the 3-second syncs were the only significant flash writer on the test unit. With it off, the unit's flash saw a handful of small writes an hour, and its most-worn block had been erased 11 times.

If the device still resets with diagnostics on, and the kernel log just stops with no panic, suspect power. Many router USB ports can't supply the current the stick draws under 5G load; try a powered USB 3 hub.

Evidence collected on every boot:

* `log/heartbeat.log`: one line every 5 minutes; a `--- boot` line marks each new boot;
* `log/modem-crashes.log`: each baseband crash and how it was handled;
* `log/vosclean.log`: "previous boot's last heartbeat";
* `log/qcmd-writes.log` and `log/qm-requests.log`: every write or command, and every UI action.

If you see reboots too, please open an issue with those logs (redact your IMEI and phone number).
