# 4. First access: root SSH

With the dongle plugged into your computer in its default mode, the computer gets an address in `192.168.225.0/24`, and the modem is `192.168.225.1`.

```bash
ssh root@192.168.225.1
```

* **The stock root password is Qualcomm's reference default, `oelinux123`.** It is published in the eko.one.pl thread, so **everybody knows it**. vosclean turns password login off once your key is in place.
* **The host key changes after every reboot, until vosclean is installed.** Stock firmware generates SSH host keys in RAM (`/var/run/ssh`) at boot, so after a reboot you'll see the "REMOTE HOST IDENTIFICATION HAS CHANGED" warning. Clear it with `ssh-keygen -R 192.168.225.1`. vosclean saves the keys once and restores them on every boot.

## Your SSH key

If you don't have a key yet, create one:

```bash
ssh-keygen -t ed25519            # creates ~/.ssh/id_ed25519 and id_ed25519.pub
```

`install.sh --pubkey ~/.ssh/id_ed25519.pub` puts it in `/data/vosclean/roothome/.ssh/authorized_keys`. That folder is bind-mounted over root's home on every boot, because root's real home is on the read-only rootfs.

**About password login:**
* Once a key is present, `SSH_PASSWORD_AUTH=no` in `vosclean.conf` turns password login off, and root is limited to `prohibit-password`.
* If no key is present, vosclean refuses to switch passwords off, so you can't lock yourself out by accident.
* To get password login back, set `SSH_PASSWORD_AUTH=yes`, then run `vosclean apply`.

## Changing the root password anyway

```sh
passwd
```

On this firmware `/etc/shadow` is a bind mount from `/systemrw`, so the change persists. A vendor helper (`cei_check_passwd.sh`) only rebuilds the file if it is empty or truncated.

## Read-only probe (optional)

`tools/vos_readonly_probe.sh` collects a full read-only inventory: firmware, interfaces, `cricli` queries and Compal AT info commands. It only reads; nothing is written, installed, started or stopped. Run it from your computer:

```bash
ssh root@192.168.225.1 'sh -s' < tools/vos_readonly_probe.sh > probe.txt 2>&1
```

Compare yours with [the probe of the unit this guide was written on](reference/probe-VOS5-GC-1-326_0R19.txt): firmware `RXMG1.20.00.326_0R19`, RF card 681, Three UK, LTE B1 + B3. Differences in the firmware version, `RFC_ID`, `SKU` or the AT command answers are the ones that matter.

The raw output includes your IMEI, IMSI, ICCID, serial numbers, IP addresses and cell location. To share it (in an issue, say), redact it first and read the result before posting:

```bash
sh tools/redact_probe.sh probe.txt > probe-redacted.txt
```

`redact_probe.sh` needs `perl` (built into macOS and nearly every Linux). It blanks those identifiers and keeps what's useful to compare: band, channel, PCI, signal levels and firmware details.
