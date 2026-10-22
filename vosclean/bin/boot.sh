#!/bin/sh
# vosclean boot entry. Called in the background from /oem/script/oem_init_post.sh.
VC=/data/vosclean
[ -f $VC/ENABLED ] || exit 0
mkdir -p $VC/log
HB=$VC/log/heartbeat.log
# what did the previous boot look like just before it ended?
[ -s $HB ] && echo "$(date -u '+%F %T') previous boot's last heartbeat: $(tail -1 $HB)" >> $VC/log/vosclean.log
echo "$(date -u '+%F %T') boot (uptime $(cut -d' ' -f1 /proc/uptime))" >> $VC/log/vosclean.log
echo "--- boot $(cat /proc/sys/kernel/random/boot_id)" >> $HB
[ -f $VC/DIAG ] && [ -x $VC/bin/diag.sh ] && systemd-run --unit=vosclean-diag $VC/bin/diag.sh >/dev/null 2>&1
sleep 20   # let QCMAP/IPACM finish their own iptables setup first
$VC/bin/vosclean apply
# light watchdog + heartbeat (persistent, so a reboot leaves evidence)
while [ -f $VC/ENABLED ]; do
  sleep 60
  $VC/bin/vosclean watch
  qpid=$(systemctl show -p MainPID --value qmanager 2>/dev/null)
  qrss=$( [ -n "$qpid" ] && [ "$qpid" != 0 ] && grep VmRSS /proc/$qpid/status 2>/dev/null | awk '{print $2}')
  echo "$(date -u '+%F %T') up=$(cut -d' ' -f1 /proc/uptime) memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)k load=$(cut -d' ' -f1-3 /proc/loadavg) qm_rss=${qrss:-0}k procs=$(ls /proc | grep -c '^[0-9]')" >> $HB
  [ $(wc -l < $HB) -gt 3000 ] && tail -n 1500 $HB > $HB.tmp && mv $HB.tmp $HB
done
