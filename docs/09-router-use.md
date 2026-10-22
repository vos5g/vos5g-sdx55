# 9. Using the dongle with a router, and other UIs

Most of this comes from the eko.one.pl thread.

## OpenWrt

* **MBIM** (default PID `9063`) is the most reliable option. Use `wwand` / `umbim`, and if needed add `"05c6:9063": {"*": {"mode":"MBIM"}}` to `/etc/usb-mode.json`.
* **RNDIS/ECM** is reported stable at about 200 Mb/s.
* **Turn off IP pass-through** in the modem's NAT settings when it sits behind a router. Otherwise the link drops after about 26 seconds.
* **Power, which is the most common problem:** the stick draws a lot under 5G load. On a GL.iNet GL-MT1300 (Beryl), the stick reset every 2–10 minutes when powered from the router's USB port. These were abrupt warm resets: no shutdown and no panic. Feeding it separate power (a powered hub or a USB power injector) fixed it completely.
* **Stock GL.iNet firmware lists the stick as "Android Tethering":** in the default mode (`9063`), a Linux host picks configuration 1 (ECM), so the stick appears as a USB network adapter with the modem doing the NAT. This works fine. See below for modem (MBIM) mode.
* **Reconnect loop when first plugged in:** Compal's USB driver has a workaround for Macs. If the host doesn't start polling the ECM data endpoint straight after enumeration, it logs `MacBook ecm initial failure ep hang` and forces a USB disconnect and re-enumeration. A router that brings the interface up slowly can trigger this 10–20 times in a row: the router shows the tethering connection "connecting" over and over. It settled by itself within about a minute on the test unit. If it doesn't, plug the stick in after the router has finished booting. There is no runtime switch to turn the check off.
* **Ethernet:** the firmware includes RTL8125 and AQC107 drivers. On an M.2 carrier with an RTL8125, the module gets its own `eth0`.

## Other UIs

* **[luci-app-5gmodem](https://github.com/fildunsky/luci-app-5gmodem)** runs on the router (LuCI), not on the dongle. It lists "Compal RXM-G1 (SG500M2-X)" as tested, and talks to the modem through ModemManager/QMI (mode `9091`). Nothing gets installed on the modem.
* **Simple Admin / QManager unmodified:** they need Quectel AT commands and show empty pages. Use the QManager port in this repo instead.
* **[iamromulan's RGMII toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit)** targets the same SoC family. Its generic pieces (Entware, Tailscale, ttyd) can be adapted to `/data`. Its installer assumes Quectel paths, so don't run it as-is.

## Running QManager on both

QManager from this repo runs **on the dongle**, so it works the same whether the host is a Mac, a PC or a router. When the dongle sits behind an OpenWrt router, reach the UI at `192.168.225.1:8080` from the router's LAN. You may need a route or firewall rule on the router for that subnet, or set up an SSH tunnel.
