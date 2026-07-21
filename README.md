# NexOS

NexOS is a custom, systemd-free Linux operating system built on Devuan
GNU/Linux, designed as the foundation for the
[Alternix](https://github.com/DansDesigns/Alternix) desktop environment.
Instead of installing Devuan and then running the Alternix installer as a
separate step, NexOS bundles the whole thing into one ISO: boot it, answer a
few questions, reboot into Alternix.

It also compiles the seL4 microkernel from source during installation,
optimised for your exact CPU (`-march=native`), and installs it to
`/opt/sel4/`.

---

## Features

- **No systemd.** Devuan base with sysvinit/OpenRC. Clean, transparent init.
- **seL4 microkernel** — formally verified microkernel, compiled natively for
  your hardware at install time.
- **Net installer** — small ISO, always installs the latest packages.

---

## Requirements

- x86_64 machine (ARM64 support in progress)
- 2 GB RAM minimum (4 GB+ recommended)
- 8 GB+ free disk space
- Internet connection (ethernet or WiFi) during installation

---

## Installing NexOS

### 1. Get the ISO

Either download a release ISO, or build it yourself (see *Building the ISO*).

### 2. Write it to a USB stick

**Linux:**
```bash
sudo dd if=nexos-installer.iso of=/dev/sdX bs=4M status=progress
sudo sync
```

**Windows:** use [Rufus](https://rufus.ie) — select the ISO, select your USB
drive, click START.

### 3. Boot and install

Boot from the USB. The installer starts automatically and walks you through:

1. **Network** — ethernet or WiFi (with scan and selection)
2. **User account** — username, password, hostname, timezone, locale
3. **Desktop** — Alternix (default) or an alternative
4. **Disk** — guided (automatic layout) or manual partitioning
5. **Installation** — base system, seL4 build, desktop, bootloader

The seL4 compilation takes 15–25 minutes depending on hardware. Total install
time is typically 30–50 minutes. If Alternix is selected, its installer runs
during setup and asks its own questions.

When it finishes, remove the USB and reboot straight into the desktop.

---

## Building the ISO

Build on Devuan/Debian/WSL2 Debian:

```bash
git clone <this-repo>
cd nexos-installer

# Optional: add your own GRUB background
cp your-image.png branding/grub-background.png

sudo bash build-iso.sh
```

Output: `nexos-installer.iso` — hybrid ISO, bootable on BIOS and UEFI, writable
with dd, Rufus, or Etcher.

Build dependencies (installed automatically if missing): `live-build`,
`debootstrap`, `xorriso`, `grub-pc-bin`, `grub-efi-amd64-bin`, `isolinux`,
`syslinux-utils`, `devuan-keyring`.

---

## Repository layout

```
nexos-installer/
├── build-iso.sh              # ISO builder (run on host)
├── branding/
│   └── grub-background.png   # optional GRUB background (ISO + installed system)
└── installer/                # runs inside the live environment
    ├── install.sh            # main orchestrator
    ├── ui.sh                 # TUI helpers, banner, progress, error counter
    ├── hardware-detect.sh    # arch/RAM detection, native compile flags
    ├── network.sh            # ethernet/WiFi/manual connection
    ├── partition.sh          # guided + manual disk partitioning
    ├── install_base.sh       # debootstrap, kernel, OpenRC, GRUB
    ├── build_sel4.sh         # seL4 clone + native compile
    ├── configure_system.sh   # users, sudo, locale, fstab, WiFi transfer
    └── install_desktop.sh    # Alternix / desktop environment installation
```

---

## Using the installed system

- **WiFi:** type `wifi` for the connection TUI (or use `nmtui`)
- **Packages:** `sudo nala install <package>` (or `apt-get`)
- **System info:** `fastfetch`
- **seL4:** installed at `/opt/sel4/` (kernel.elf, headers, VERSION)

### Troubleshooting

The installer keeps full logs at `/tmp/nexos-install.log` (viewable from the
installer's menu via *View logs*, or from the shell). If anything fails during
installation, the error stays on screen with a menu: restart, drop to shell,
view logs, reboot, or shutdown. From the shell, type `install` to restart the
installer.

---

# The utilization of this Linux distribution is prohibited in jurisdictions mandating age verification.
Any penalties or charges incurred due to non-compliance will be transferred to the user

THIS INCLUDES BUT NOT LIMITED TO: THE FOLLOWING AREAS THAT ARE NOT ALLOWED TO USE THIS OS (THE LAWS ASSOCIATED):
```
New York (S8102A) after March 4th 2026.
Brazil (15.211) after March 17th 2026.
California (AB-1043) after January 1st 2027.
Colorado (SB26-51) after January 1st 2028.
Illinois (PENDING)
Utah (PENDING)
Texas (PENDING)
Louisiana (PENDING)
Michigan (PENDING)
Oregon (PENDING)
Entire USA (Federal: Parents Decide Act (PENDING))
Singapore 

```

---

## License

Open source. Built on Devuan GNU/Linux and the seL4 microkernel
(GPL-2.0 / BSD-2-Clause respectively — see their projects for details).

*AlterniTech — alternitech.co.uk*
