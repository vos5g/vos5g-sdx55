#!/bin/sh
# VOS read-only probe. Runs on the modem via:  ssh root@192.168.225.1 'sh -s' < vos_readonly_probe.sh > probe.txt 2>&1
# Only queries: no settings are written, nothing is installed, no services are started or stopped.
if timeout 1 true 2>/dev/null; then T="timeout 10"; else T="timeout -t 10"; fi
run() { echo; echo "##### $*"; $T "$@" 2>&1; echo "## rc=$?"; }
# atcli shares one channel with QManager's qcmd and can hand back a reply meant
# for someone else. Take qcmd's lock while asking, and retry until the reply
# starts with the echo of our own command.
LOCK=/tmp/qcmd-cache/modem.lock
at() {
  echo; echo "##### atcli $1"
  i=1
  while :; do
    if [ -d /tmp/qcmd-cache ] && command -v flock >/dev/null 2>&1; then out=$($T flock $LOCK atcli "$1" 2>&1); else out=$($T atcli "$1" 2>&1); fi
    first=$(printf '%s\n' "$out" | tr -d '\r' | sed -n '/[^ ]/{p;q;}')
    { [ "$first" = "$1" ] || [ $i -ge 5 ]; } && break
    i=$((i + 1)); sleep 1
  done
  printf '%s\n' "$out"; echo "## tries=$i"
}

echo "probe start: $(date -u) uptime: $(cat /proc/uptime)"
run cat /etc/version /oem/cei_module_ver_vos_id
run sh -c 'ip addr; echo; ip route; echo; ip -6 route | head -20'
run df -h / /data /oem /systemrw /tmp
run free
run sh -c 'for b in atcli cricli qmicli mbimcli socat curl wget iptables ip6tables ebtables opkg timeout logger sendmail; do printf "%-10s %s\n" $b "$(command -v $b)"; done'
run sh -c 'ls -l /dev/smd* /dev/at_* /dev/ttyGS* /dev/net/tun 2>/dev/null'
run sh -c 'cat /etc/usb/boot_hsusb_comp; ls /sys/kernel/config/usb_gadget/*/functions 2>/dev/null'
run sh -c 'lighttpd -V | head -2; grep -E "server.port|server.modules|ssl.engine|auth" /etc/lighttpd.conf | grep -v "^ *#" | head -20'
run sh -c 'systemctl is-active sshd.socket rpcbind.socket rpcbind nfs-server fotaclient.timer lighttpd 2>&1'

# Compal radio CLI: query sub-commands only (the set_* commands are never called)
run cricli
for c in signal band band_cap cell_location get_cell_config get_nr5g_cell_config get_pref_band get_nr5g_mode get_lte_band_pri get_nr5g_band_pri; do run cricli $c; done

# AT queries only (read/test forms)
at 'ATI'
for c in 'AT+PRODUCTINFO' 'AT+BINFO' 'AT+BNRINFO' 'AT+LCAINFO' 'AT+NRCAINFO' 'AT+BCONFIG?' 'AT+USBCOMP?' \
         'AT+CESQ' 'AT+CSQ' 'AT+COPS?' 'AT+CEREG?' 'AT+C5GREG?' 'AT$QCSYSMODE?' 'AT$QCRSRP?' 'AT$QCRSRQ?' \
         'AT+CPMS?' 'AT+CMGF?' 'AT+CNMI?' 'AT+CGDCONT?' 'AT+5GDISP?' 'AT+BINFO=?' 'AT+BCONFIG=?' 'AT+CEISWITCHSIM?' \
         'AT+QCVER' 'AT+CEITHERM?' 'AT+CEISAR?' 'AT+CESQDBM' 'AT+ANTSWITCH?' 'AT+BNMEA?' 'AT+BGPSPRM?' 'AT+BATLOG?'; do at "$c"; done
run sh -c 'cat /firmware/image/Ver_Info.txt; ls /firmware/image/modem_pr/so'
echo; echo "probe end: $(date -u)"
