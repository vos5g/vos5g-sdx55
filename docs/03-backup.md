# 3. Backups that can actually be restored

Do this **before** installing anything. You want three things:

| What | Covers | Tool |
|---|---|---|
| **QCN** | EFS/NV: IMEI, RF calibration, band and carrier settings | QPST / QFIL on Windows, over the DIAG port |
| **UBI volumes** | rootfs, `/data`, `/systemrw`, `/persist`, `/cache`, `/oem` | `tools/backup-ubi.sh` from Mac or Linux |
| Raw boot partitions (optional) | sbl, tz, abl, boot, recovery, … | Read-only MTD reads, **excluding efs2 and ddr** |

## Why not just `dd` the whole flash?

* **`efs2` (mtd2) is TrustZone-protected.** Reading it from Linux **resets the modem** mid-read. This was reproduced while making this guide's backups. Use QCN for EFS instead.
* **Raw NAND images of `system` (mtd25) could not be restored.** Forum users tried EDL, QFIL and fastboot, and all failed with ECC/CRC errors, because none of those tools handle this chip's bad-block layout. A per-volume UBI image, written back with `ubiupdatevol` **from the modem's own Linux**, avoids that problem.

## 1. QCN with QPST (Windows)

1. Switch the dongle to a mode that exposes DIAG. The easiest way is Tri Cascade's **Switch_Tool**, set to RNDIS, or `9165` (see [01-device.md](01-device.md#usb-modes)).
2. Install the Qualcomm USB drivers, then use QPST Configuration to check that the port shows up.
3. Use **QPST Software Download → Backup**, or **QFIL → Tools → QCN Backup Restore**, to save a `.qcn` / `.xqcn`. Also save the "multisim" variant if it's offered.
4. Switch back to the default mode (`9063`).

The QCN contains your IMEI. Keep it private, and store a copy off the computer.

## 2. UBI volumes from the computer

The modem's own `/tmp` is tiny, so the script streams each volume over SSH and compresses it on your computer:

```bash
./tools/backup-ubi.sh                     # ubi0_0..4 + ubi2_0 (oemfs), plus ubinfo -a and SHA256SUMS
./tools/backup-ubi.sh --with-modem-fw     # also ubi1_0 (baseband fw, about 93 MiB; the OTA package has it too)
```

The script checks that each decompressed image is exactly the size the volume reports. You can open an image offline as a filesystem with [ubi_reader](https://github.com/onekey-sec/ubi_reader) to check it, e.g. `ubireader_extract_files`.

Volume map on a v73 unit:

| Device | Name | Size | Mounted at |
|---|---|---|---|
| ubi0_0 | rootfs | 110.1 MiB | `/` (ro) |
| ubi0_1 | usrfs | 107.7 MiB | `/data` |
| ubi0_2 | cachefs | 15.0 MiB | `/cache` |
| ubi0_3 | systemrw | 6.0 MiB | `/systemrw` |
| ubi0_4 | persist | 6.0 MiB | `/persist` |
| ubi1_0 | modem | 93.2 MiB | `/firmware` |
| ubi2_0 | oemfs | 31.0 MiB | `/oem` |

### Restoring a volume (not tested end-to-end)

From the modem's shell, with the image copied onto it, unmount the volume first if it is mounted:

```sh
gunzip -c ubi0_3_systemrw.ubifs.gz > /tmp/v.img   # small volumes; stream big ones over SSH instead
ubiupdatevol /dev/ubi0_3 /tmp/v.img
```

For the root filesystem (`ubi0_0`, which is mounted while the system is running), restore from a recovery environment, or stream the image directly:
`gunzip -c ubi0_0_rootfs.ubifs.gz | ssh root@192.168.225.1 'ubiupdatevol /dev/ubi0_0 -s 115548160 -'`.
Treat that as a last resort. Check the size against your saved `ubinfo-a.txt`.

## 3. Raw partition images (optional)

Images of the boot chain (sbl, mibib, tz, tz_devcfg, apdp, xbl_config, multi_image, aop, qhee, abl, uefi, boot, misc, devinfo, recovery, fota, recoveryfs, sec, oem, system) are useful for analysis and as a reference for EDL. Read them with `nanddump` or `cat /dev/mtdN` over SSH, **skipping mtd2 (efs2) and mtd5 (ddr)**. Read each one twice and compare the hashes. Expect bad-block differences to make them unsuitable as a direct restore image for `system`.

## Checklist

- [ ] `.qcn` saved (and the multisim variant), stored off the computer
- [ ] `VOS_UBI_BACKUP_*` folder with `ubinfo-a.txt` and a `SHA256SUMS.txt` that verifies
- [ ] Optional: raw images of the boot partitions
- [ ] A second copy of all of it on separate storage
