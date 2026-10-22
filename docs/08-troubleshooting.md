# 8. Troubleshooting, uninstalling and recovery

## Logs (all in `/data/vosclean/log/`)

| File | Contents |
|---|---|
| `vosclean.log` | Each apply step, firewall and DNS re-applies, the previous boot's last heartbeat |
| `heartbeat.log` | One line a minute: uptime, available memory, load, QManager RSS, process count |
| `qmanager.log` | QManager stdout/stderr |
| `qm-requests.log` | Every state-changing QManager HTTP request (no bodies) |
| `qcmd-writes.log` | Every state-changing AT/cricli command and the process that sent it |

## Common problems

| Symptom | Cause / fix |
|---|---|
| Host-key warning after every reboot | vosclean isn't running yet (see the next row), or `PERSIST_HOSTKEYS=no` |
| Nothing from vosclean after a reboot | `oem_init_post.sh` isn't executable (`systemctl status oeminit_post` shows 203/EXEC). Fix: `chmod 755 /oem/script/oem_init_post.sh`. The installer does this for you |
| Key login refused after a reboot | Check `vosclean status` for "roothome bound". The `/home/root` bind mount comes from `/data/vosclean/roothome` |
| Locked out of SSH | Password login is off and the key was lost. Switch to mode `9165` with Switch_Tool (Windows). Its ADB interface should give you a root shell (not tested). From that shell, delete `/data/vosclean/ENABLED` and reboot |
| QManager pages empty / "ERROR" | `qcmd` missing or not executable: `ls -l /data/vosclean/qm/bin`. Run `qcmd 'AT+QENG="servingcell"'` by hand |
| QManager login refused | Run `vosclean qmpass` again |
| AT replies scrambled | Two programs are polling the AT channel at once. Don't run the stock UI's status page and QManager side by side for long; the old `UI_ENABLE` UI has its own poller |
| Custom DNS not applied | `vosclean status` shows the state. Check `etc/dns.conf` and `iptables -t nat -S VOS_DNS` |
| Busybox `timeout` errors in your own scripts | Busybox uses `timeout -t SECONDS`, not GNU syntax |

## Kill switch and uninstall

```sh
rm /data/vosclean/ENABLED && reboot      # boot exactly as stock (the hook line is still there but does nothing)
/data/vosclean/bin/uninstall.sh          # remove the hook line and undo the runtime changes now
rm -rf /data/vosclean                    # delete everything (saved host keys, logs, QManager settings)
```

`uninstall.sh` stops QManager and the minimal UI, removes the firewall chains and the DNS DNAT chain, unmounts the `fotaclient` stub and the sshd config, and unmasks the vendor units. The `/home/root` key mount stays until the next reboot.

A **factory reset** from the stock web UI wipes `/data`, which removes vosclean. The hook line in `/oem` is then harmless, because `ENABLED` is gone. It also reverts EFS band-policy edits.

## If the device stops booting

vosclean never writes boot partitions or the rootfs, so a boot failure after installing it would be very unusual. Deleting `/data/vosclean/ENABLED` brings back stock behaviour. If you've been experimenting further, the escalation path is:

1. **Recovery / fastboot.** `/sbin/reboot-bootloader` and `/sbin/reboot-recovery` set a reboot cookie, and fastboot accepts `flash`/`erase` (use `-S 256M` for big images). Recovery installs unsigned OTA ZIPs.
2. **The vendor's Windows updater** (`VOS_Dongle_Upgrade_v73.exe`). It applies **patch-based** OTAs, so it needs an intact system. It isn't a blank-flash restore.
3. **EDL (9008)** through test points on the board, with [`bkerler/edl`](https://github.com/bkerler/edl) and an SDX55 loader (a Quectel RG502 one has been reported to work). This is the route for writing partitions when nothing else boots. Remember the bad-block caveat for raw `system` images in [03-backup.md](03-backup.md).
4. **QCN restore** with QPST if NV/EFS was damaged. A symptom is the radio stuck at `+CFUN: 5`.
