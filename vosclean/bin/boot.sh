#!/bin/sh
# vosclean boot entry. Called in the background from /oem/script/oem_init_post.sh.
VC=/data/vosclean
[ -f $VC/ENABLED ] || exit 0
[ -f $VC/etc/vosclean.conf ] && . $VC/etc/vosclean.conf
RAM=/tmp/vosclean/log            # chatty logs live in RAM (tmpfs) to spare the NAND
mkdir -p $VC/log $RAM
HB=$VC/log/heartbeat.log         # flight recorder: stays on flash so an unexpected reset leaves evidence
HB_EVERY=${HEARTBEAT_MINUTES:-5}

# keep the tail of the RAM logs on flash when the system shuts down cleanly
save_ram_logs() {
  mkdir -p $VC/log/last-boot
  for f in $RAM/*.log; do [ -f "$f" ] && tail -n 300 "$f" > "$VC/log/last-boot/$(basename "$f")"; done
  echo "$(date -u '+%F %T') clean shutdown: RAM logs saved to log/last-boot/" >> $VC/log/vosclean.log
  exit 0
}
trap save_ram_logs TERM INT

# what did the previous boot look like just before it ended?
[ -s $HB ] && echo "$(date -u '+%F %T') previous boot's last heartbeat: $(tail -1 $HB)" >> $VC/log/vosclean.log
echo "$(date -u '+%F %T') boot (uptime $(cut -d' ' -f1 /proc/uptime))" >> $VC/log/vosclean.log
echo "--- boot $(cat /proc/sys/kernel/random/boot_id)" >> $HB
# radio-only restart on a modem crash, set as early as possible
$VC/bin/vosclean ssr
[ -f $VC/DIAG ] && [ -x $VC/bin/diag.sh ] && systemd-run --unit=vosclean-diag $VC/bin/diag.sh >/dev/null 2>&1
sleep 20   # let QCMAP/IPACM finish their own iptables setup first
$VC/bin/vosclean apply
# light watchdog every minute; heartbeat line every $HB_EVERY minutes
n=0
while [ -f $VC/ENABLED ]; do
  sleep 60 & wait $!          # wait (not a plain sleep) so the TERM trap runs at once
  $VC/bin/vosclean watch
  n=$((n + 1))
  [ $((n % HB_EVERY)) -eq 0 ] || continue
  qpid=$(systemctl show -p MainPID --value qmanager 2>/dev/null)
  qrss=$( [ -n "$qpid" ] && [ "$qpid" != 0 ] && grep VmRSS /proc/$qpid/status 2>/dev/null | awk '{print $2}')
  crash=$(cat /tmp/vosclean-ssr.count 2>/dev/null)
  echo "$(date -u '+%F %T') up=$(cut -d' ' -f1 /proc/uptime) memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)k load=$(cut -d' ' -f1-3 /proc/loadavg) qm_rss=${qrss:-0}k procs=$(ls /proc | grep -c '^[0-9]') modem_crashes=${crash:-0}" >> $HB
  [ $(wc -l < $HB) -gt 3000 ] && tail -n 1500 $HB > $HB.tmp && mv $HB.tmp $HB
done
