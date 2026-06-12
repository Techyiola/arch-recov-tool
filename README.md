# arch-recov-tool

A diagnostic tool for non-booting Arch Linux systems. Run it from an Arch
ISO (live environment) to find out *why* your system won't boot — with
special attention to issues caused by AUR/foreign packages, broken
initramfs images, bootloader misconfigurations, and bad fstab entries.

It is **read-only / diagnostic by default** — it never modifies your
system. It tells you what's wrong and suggests the fix command to run
yourself.

## What it checks

- **Bootloader** — systemd-boot loader entries or GRUB config: missing
  kernel/initramfs files, missing menuentries, stale root UUIDs.
- **fstab** — resolves UUID=/LABEL= entries and verifies the underlying
  devices actually exist.
- **mkinitcpio** — missing initramfs images for installed kernels, and
  whether `nvidia-dkms` users have the right hooks/modules configured
  (a very common cause of black-screen boots after driver updates).
- **Last boot journal errors** — pulls `err`-level messages from the
  previous boot's systemd journal.
- **Foreign/AUR packages** — lists AUR-installed packages, cross-references
  recent pacman transactions to flag packages updated right before things
  broke, and checks for unmerged `.pacnew` config files.

## Usage

Boot into an Arch Linux live ISO, connect to the internet, then:

```bash
curl -O https://raw.githubusercontent.com/Techyiola/arch-recov-tool/main/arch-recovery.sh
sudo bash arch-recovery.sh
```

The tool will:
1. List candidate root partitions and ask you to pick yours (or auto-select
   if there's only one).
2. Mount it (and the boot/ESP partition if separate).
3. Run all checks, printing `[PASS]`, `[WARN]`, or `[FAIL]` for each.
4. Print a summary and optionally save a report to a text file.

## Example output

```
== Bootloader check ==
[INFO] systemd-boot detected (loader entries present).
[INFO] Checking /mnt/arch-recovery/boot/loader/entries/arch.conf
[PASS] Kernel image referenced by arch.conf exists (/vmlinuz-linux)
[FAIL] Initramfs /initramfs-linux.img referenced in arch.conf is MISSING

== Initramfs / mkinitcpio config ==
[PASS] /etc/mkinitcpio.conf exists
[WARN] nvidia-dkms is installed but no nvidia modules/hooks found in
       mkinitcpio.conf — initramfs may be missing nvidia driver
```

## Contributing

PRs welcome, especially new check functions! Each check should be:

- An independent bash function (`check_xxx`)
- Safe to run on any setup (fail gracefully if files/tools are missing)
- Read-only — print suggested fix commands, don't run them

## Disclaimer

This tool is provided as-is. It's diagnostic only and does not modify your
system, but always make sure you have backups before troubleshooting a
broken install.

## License

GPLv3 — see [LICENSE](LICENSE).
