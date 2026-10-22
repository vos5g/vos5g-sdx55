# 9. Using the dongle with a router, and other UIs

Most of this comes from the eko.one.pl thread.

## OpenWrt

* **MBIM** (default PID `9063`) is the most reliable option. Use `wwand` / `umbim`, and if needed add `"05c6:9063": {"*": {"mode":"MBIM"}}` to `/etc/usb-mode.json`.
* **RNDIS/ECM** is reported stable at about 200 Mb/s.
* **Turn off IP pass-through** in the modem's NAT settings when it sits behind a router. Otherwise the link drops after about 26 seconds.
* **Power:** the stick draws a lot under 5G load. Use a strong USB 3 port or a powered hub.
* **Ethernet:** the firmware includes RTL8125 and AQC107 drivers. On an M.2 carrier with an RTL8125, the module gets its own `eth0`.

## Other UIs

* **[luci-app-5gmodem](https://github.com/fildunsky/luci-app-5gmodem)** runs on the router (LuCI), not on the dongle. It lists "Compal RXM-G1 (SG500M2-X)" as tested, and talks to the modem through ModemManager/QMI (mode `9091`). Nothing gets installed on the modem.
* **Simple Admin / QManager unmodified:** they need Quectel AT commands and show empty pages. Use the QManager port in this repo instead.
* **[iamromulan's RGMII toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit)** targets the same SoC family. Its generic pieces (Entware, Tailscale, ttyd) can be adapted to `/data`. Its installer assumes Quectel paths, so don't run it as-is.

## Running QManager on both

QManager from this repo runs **on the dongle**, so it works the same whether the host is a Mac, a PC or a router. When the dongle sits behind an OpenWrt router, reach the UI at `192.168.225.1:8080` from the router's LAN. You may need a route or firewall rule on the router for that subnet, or set up an SSH tunnel.
