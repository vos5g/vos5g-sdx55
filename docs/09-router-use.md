# 9. Using the dongle with a router, and other UIs

Most of this comes from the eko.one.pl thread.

## OpenWrt

* **MBIM** (default PID `9063`) is the most reliable option. Use `wwand` / `umbim`, and if needed add `"05c6:9063": {"*": {"mode":"MBIM"}}` to `/etc/usb-mode.json`.
* **RNDIS/ECM** is reported stable at about 200 Mb/s.
* **Turn off IP pass-through** in the modem's NAT settings when it sits behind a router. Otherwise the link drops after about 26 seconds.
* **Power, which is the most common problem:** the stick draws a lot under 5G load. On a GL.iNet GL-MT1300 (Beryl), the stick reset every 2–10 minutes when powered from the router's USB port. These were abrupt warm resets: no shutdown and no panic. Feeding it separate power (a powered hub or a USB power injector) fixed it completely.
* **Stock GL.iNet firmware lists the stick as "Android Tethering":** in the default mode (`9063`), a Linux host picks configuration 1 (ECM), so the stick appears as a USB network adapter with the modem doing the NAT. This works fine. For modem mode, see the MBIM bullet above.
* **Reconnect loop when first plugged in:** Compal's USB driver has a workaround for Macs. If the host doesn't start polling the ECM data endpoint straight after enumeration, it logs `MacBook ecm initial failure ep hang` and forces a USB disconnect and re-enumeration. A router that brings the interface up slowly can trigger this 10–20 times in a row: the router shows the tethering connection "connecting" over and over. It settled by itself within about a minute on the test unit. If it doesn't, plug the stick in after the router has finished booting. There is no runtime switch to turn the check off.
* **QMI (`9064` configuration 1):** turn on [router modem mode](#router-modem-mode-qmi-on-openwrt), otherwise the router's data call fails.
* **Ethernet:** the firmware includes RTL8125 and AQC107 drivers. On an M.2 carrier with an RTL8125, the module gets its own `eth0`.

## Router modem mode (QMI on OpenWrt)

In USB mode `9064` (QManager → System Settings → USB mode), a router can select **configuration 1 (QMI/rmnet)** and use the stick as a plain modem with OpenWrt's `proto qmi` (`uqmi`), for example by writing `1` to the device's `bConfigurationValue` from a hotplug script.

**The stick's own data call gets in the way.** The stick keeps its own connection (QCMAP's "backhaul") on the SIM's APN, and the network allows only one call on it. The router's `uqmi --start-network` then fails with `Call failed`, even though signal and registration look fine. This is the same cause as [luci-app-5gmodem issue #53](https://github.com/fildunsky/luci-app-5gmodem/issues/53).

**Router modem mode** (`HOST_MODEM=auto`) handles this automatically. A small daemon (`vos-hostmodem`, `bin/hostmodem.sh`) checks USB every 2 seconds:

* **The host has the modem:** USB is configured in a mode that offers QMI or MBIM, but neither `ecm0` nor `rndis0` is up for 6 seconds. The daemon turns QCMAP's auto-connect off and drops the stick's own call, so the router's call goes through.
* **USB tethering is back, or the stick is unplugged:** the daemon turns auto-connect on and reconnects.

While the router has the connection:

* The stick has no internet of its own. Tailscale, NetBird, the DNS proxy and email alerts on the stick are offline.
* QManager's watchdog and its connection alerts pause. Each hand-over is listed under Recent activity.
* QManager can't be reached over USB, since there's no USB network. It's back once a computer uses the stick over tethering.

QCMAP saves the auto-connect setting across reboots. The daemon keeps a marker (`state/hostmodem-released`) while auto-connect is off, and turns it back on as soon as no host is using the modem. That includes after a reboot, when the feature is switched off, and during `uninstall.sh`. QCMAP ignores the change for about a minute after boot, so the daemon retries it.

Switch the feature with `vosclean hostmodem on|off`, or in QManager → System Settings → USB mode. `vosclean hostmodem` shows the current state, and each transition is logged in `log/vosclean.log`.

**GL.iNet firmware:** its `cellular_manage` service doesn't recognise the stick in QMI mode and power-cycles the USB port. Use stock OpenWrt, or stop `cellular_manage` and set up the interface yourself.

## Other UIs

* **[luci-app-5gmodem](https://github.com/fildunsky/luci-app-5gmodem)** runs on the router (LuCI), not on the dongle. It lists "Compal RXM-G1 (SG500M2-X)" as tested, and talks to the modem through ModemManager/QMI (mode `9091`). Nothing gets installed on the modem.
* **Simple Admin / QManager unmodified:** they need Quectel AT commands and show empty pages. Use the QManager port in this repo instead.
* **[iamromulan's RGMII toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit)** targets the same SoC family. Its generic pieces (Entware, Tailscale, ttyd) can be adapted to `/data`. Its installer assumes Quectel paths, so don't run it as-is.

## Running QManager on both

QManager from this repo runs **on the dongle**, so it works the same whether the host is a Mac, a PC or a router. When the dongle sits behind an OpenWrt router, reach the UI at `192.168.225.1:8080` from the router's LAN. You may need a route or firewall rule on the router for that subnet, or set up an SSH tunnel.
