#!/bin/sh
# Remove the boot hook and undo the live changes (files in /data/vosclean are kept).
VC=/data/vosclean
rm -f $VC/ENABLED
sed -i '/vosclean/d' /oem/script/oem_init_post.sh
systemctl stop vosclean-boot vosclean-diag vosclean-ui vos-wg qmanager tailscaled 2>/dev/null
rm -f $VC/DIAG
for d in /sys/bus/msm_subsys/devices/*; do echo SYSTEM > $d/restart_level 2>/dev/null; done
$VC/bin/vosclean stop-fw
iptables -t nat -D OUTPUT -j VOS_DNS 2>/dev/null; iptables -t nat -F VOS_DNS 2>/dev/null; iptables -t nat -X VOS_DNS 2>/dev/null
[ -s /var/run/data/dnsmasq.pid ] && kill -HUP $(cat /var/run/data/dnsmasq.pid) 2>/dev/null
for m in /sbin/fotaclient /etc/ssh/sshd_config_readonly; do grep -q " $m " /proc/mounts && umount $m; done
systemctl unmask --runtime fotaclient.timer 'fotaclient@.service' fotaclient_init.service rpcbind.socket rpcbind.service nfs-server.service nfs-mountd.service nfs-statd.service >/dev/null 2>&1
systemctl start rpcbind.socket 2>/dev/null
echo "vosclean disabled. (/home/root key mount left until reboot; rm -rf $VC to delete everything)"
