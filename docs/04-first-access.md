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

`tools/vos_readonly_probe.sh` collects a full read-only inventory: firmware, interfaces, `cricli` queries and Compal AT info commands. It's useful for comparing your unit with the one this guide was written on:

```bash
ssh root@192.168.225.1 'sh -s' < tools/vos_readonly_probe.sh > probe.txt 2>&1
```

The output includes your IMEI, ICCID and cell details. Don't post it unredacted.
