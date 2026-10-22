#!/bin/sh
# vosclean diagnostics (enabled by /data/vosclean/DIAG): keep the kernel log on /data, record the
# PMIC power-on/reset reason of every boot, and let a baseband crash restart only the modem
# (not the whole device), so the reason of a spontaneous reset gets logged.
VC=/data/vosclean; D=$VC/log/diag; mkdir -p $D
B=$(cut -c1-8 /proc/sys/kernel/random/boot_id)
for p in kmsg msg pon; do ls -1t $D/$p-* 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null; done
for d in /sys/bus/msm_subsys/devices/*; do
  [ "$(cat $d/name)" = modem ] && echo RELATED > $d/restart_level
done
R=/sys/kernel/debug/regmap/spmi0-08
if [ -d $R ]; then
  { echo "boot $B uptime $(cut -d' ' -f1 /proc/uptime) rtc $(date -u '+%F %T')"
    for a in 0x808:2 0x8C0:16; do echo ${a%:*} > $R/address; echo ${a#*:} > $R/count; cat $R/data; done
  } > $D/pon-$B.txt 2>&1
fi
echo "$(date -u '+%F %T') diag start boot=$B modem restart_level=$(cat /sys/bus/msm_subsys/devices/subsys0/restart_level) pon=$(grep -E '^08c[0-9a-f]:' $D/pon-$B.txt 2>/dev/null | cut -d' ' -f2 | tr -d '\n')" >> $VC/log/vosclean.log
cat /dev/kmsg > $D/kmsg-$B.log &
tail -n 0 -F /var/log/messages 2>/dev/null | awk 'tolower($0) ~ /err|fail|crash|fatal|panic|reboot|reset|watchdog|ssr|subsys|oom|killed|shutdown|restart/ && $0 !~ /pam_systemd|PAM adding/ {print; fflush()}' > $D/msg-$B.log &
while :; do sleep 3; sync; done
