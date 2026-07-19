#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# build-iso.sh — NexOS Installer ISO Builder
#
# Builds a minimal Devuan live environment containing
# the NexOS installer scripts. Uses live-build.
#
# Run as root on a Devuan/Debian host.
# Output: nexos-installer.iso
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_ISO="${SCRIPT_DIR}/nexos-installer.iso"

# ── Colours (minimal, build-time only) ───────────────────────────
_info()  { echo "  · $*"; }
_ok()    { echo "  ✓ $*"; }
_err()   { echo "  ✗ $*" >&2; }
_die()   { _err "$*"; exit 1; }
_step()  { echo ""; echo "  ══  $*  ══"; echo ""; }

# ── Root check ────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || _die "Run as root: sudo bash build-iso.sh"

# ── Dependencies ──────────────────────────────────────────────────
_step "Checking dependencies"

for dep in live-build debootstrap xorriso grub-pc-bin grub-efi-amd64-bin isolinux syslinux-utils; do
    if ! dpkg -l "$dep" &>/dev/null; then
        _info "Installing ${dep}..."
        apt-get install -y "$dep" &>/dev/null
    fi
done

# Install Devuan keyring so debootstrap can verify signatures
if ! dpkg -l devuan-keyring &>/dev/null; then
    _info "Installing Devuan keyring..."
    # Fetch and install the keyring package directly
    # Find the actual current keyring deb from the pool index
    keyring_deb="/tmp/devuan-keyring.deb"
    keyring_url=$(wget -qO- "http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/" 2>/dev/null |         grep -oP 'devuan-keyring_[^"]+_all\.deb' | sort -V | tail -1)
    if [[ -z "$keyring_url" ]]; then
        # Fallback to known version
        keyring_url="devuan-keyring_2022.09.04_all.deb"
    fi
    wget -q -O "$keyring_deb"         "http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/${keyring_url}" ||         _die "Failed to fetch Devuan keyring."
    dpkg -i "$keyring_deb" &>/dev/null
    rm -f "$keyring_deb"
fi

# Export Devuan keyring for debootstrap
DEVUAN_KEYRING="/usr/share/keyrings/devuan-archive-keyring.gpg"
if [[ ! -f "$DEVUAN_KEYRING" ]]; then
    # Try alternate path
    DEVUAN_KEYRING=$(dpkg -L devuan-keyring 2>/dev/null | grep '\.gpg$' | head -1)
    [[ -z "$DEVUAN_KEYRING" ]] && _die "Devuan keyring GPG file not found after install."
fi
_info "Devuan keyring: ${DEVUAN_KEYRING}"

_ok "Dependencies OK."

# ── Clean build dir ───────────────────────────────────────────────
_step "Preparing build directory"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Also clean any live-build cache that may have stale chroot state
lb clean --purge 2>/dev/null || true
_ok "Build dir: ${BUILD_DIR}"

# ── live-build configuration ──────────────────────────────────────
_step "Configuring live-build"

lb config \
    --distribution "excalibur" \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap "http://deb.devuan.org/merged" \
    --mirror-binary "http://deb.devuan.org/merged" \
    --mirror-chroot-security "http://deb.devuan.org/merged" \
    --mirror-binary-security "http://deb.devuan.org/merged" \
    --architectures "amd64" \
    --binary-images "iso-hybrid" \
    --bootloaders "grub-efi,grub-pc" \
    --iso-application "NexOS Installer" \
    --zsync "false" \
    --uefi-secure-boot "disable" \
    --memtest "none" \
    --iso-volume "NexOS-Installer" \
    --iso-application "NexOS Net Installer" \
    --iso-publisher "NexOS" \
    --apt-indices "false" \
    --apt-recommends "false" \
    --debootstrap-options "--variant=minbase --keyring=${DEVUAN_KEYRING}"

_ok "live-build configured."

# Override LB_INITSYSTEM — must be written to config/common after lb config runs.
# lb_chroot_live-packages reads LB_INITSYSTEM and installs live-config-${LB_INITSYSTEM}.
# Setting it to sysvinit installs live-config-sysvinit instead of live-config-systemd.
# Set LB_INITSYSTEM=none so live-build does not try to install live-config-systemd.
# We add live-config-sysvinit explicitly in our package list instead.
echo 'LB_INITSYSTEM="none"' >> config/common

# Find and patch lb_chroot_live-packages to skip live-config-systemd.
# On Devuan, live-config-systemd doesn't exist and causes the build to fail.
# Patch /usr/lib/live/build/config to remove live-config-systemd and systemd-sysv.
# This file hardcodes these packages — we strip them out before lb build runs.
_LB_CONFIG="/usr/lib/live/build/config"
if [ -f "$_LB_CONFIG" ]; then
    sed -i 's/live-config-systemd systemd-sysv dracut-live dracut-config-generic dracut//g' "$_LB_CONFIG"
    sed -i 's/live-config live-config-systemd systemd-sysv//g' "$_LB_CONFIG"
    sed -i 's/NEEDED_PACKAGES="${NEEDED_PACKAGES} live-config-systemd systemd-sysv"//g' "$_LB_CONFIG"
    _ok "Patched: $_LB_CONFIG"
else
    die "Cannot find $_LB_CONFIG"
fi


# ── Devuan apt keyring for binary stage ───────────────────────────
_step "Configuring Devuan apt authentication"

mkdir -p config/archives
# Tell apt in the chroot to trust Devuan's key
cp "$DEVUAN_KEYRING" config/archives/devuan.key

# Only copy the keyring — live-build writes sources.list from --mirror flags.
# Adding devuan.list here causes "configured multiple times" warnings.


# ── Block systemd packages via apt preferences ────────────────────
mkdir -p config/includes.chroot/etc/apt/preferences.d
cat > config/includes.chroot/etc/apt/preferences.d/no-systemd << 'PREFEOF'
Package: systemd systemd-sysv systemd-shim live-config live-config-systemd
Pin: release *
Pin-Priority: -1
PREFEOF

# Block Rust coreutils (uutils) — GNU coreutils only.
# The Rust rewrite still has behavioural breakage; NexOS stays on GNU.
cat > config/includes.chroot/etc/apt/preferences.d/no-rust-coreutils << 'PREFEOF'
Package: rust-coreutils rust-coreutils-* uutils-coreutils coreutils-from-uutils
Pin: release *
Pin-Priority: -1

Package: coreutils
Pin: release *
Pin-Priority: 1001
PREFEOF

# ── Package list ──────────────────────────────────────────────────
_step "Writing package lists"

mkdir -p config/package-lists

cat > config/package-lists/nexos-installer.list.chroot << 'EOF'
# ── Init system (no systemd) ─────────────────────────────────────
sysvinit-core
openrc
elogind

# ── Shell + core utils ────────────────────────────────────────────
bash
busybox
coreutils
util-linux
procps
findutils
grep
sed
gawk
less
kmod

# ── Installer requirements ────────────────────────────────────────
debootstrap
parted
gdisk
e2fsprogs
dosfstools
lvm2

# ── Network tools ─────────────────────────────────────────────────
iproute2
iputils-ping
wget
curl
ca-certificates
net-tools
iw
wireless-tools
wpasupplicant
dhcpcd5
rfkill
ethtool
nftables

# ── Wired NIC firmware + drivers ──────────────────────────────────
# Realtek (r8168, r8169 — very common on desktops/laptops)
firmware-realtek
# Intel (e1000e, igb, ixgbe — Intel NICs)
# Broadcom NICs (bnx2, tg3)

# ── WiFi firmware ─────────────────────────────────────────────────
# Intel WiFi (iwlwifi — ThinkPads, modern laptops)
firmware-iwlwifi
# Atheros (ath9k, ath10k — common in many laptops)
firmware-atheros
# Realtek WiFi (rtl8192, rtlwifi)
firmware-realtek
# Broadcom WiFi (b43, brcmsmac — MacBooks, some laptops)
firmware-brcm80211
# Ralink/MediaTek (rt2800, mt7601 — USB dongles)
# Generic free firmware
firmware-linux-free
# Non-free catch-all (covers many remaining cards)

# ── USB drivers ───────────────────────────────────────────────────
# USB mass storage + HID are built into the kernel.
# These packages support USB network adapters and input:
# USB-to-Ethernet adapters (ASIX, CDC, RTL8150)
# already covered by kernel modules — no extra firmware needed.
# USB HID (keyboards, mice) — kernel built-in, no package needed.
# USB hub / xhci / ehci — kernel built-in.
# usbutils gives lsusb for diagnostics:
usbutils

# ── Keyboard / input ──────────────────────────────────────────────
# Console keyboard maps (essential — without this kbd may be wrong layout)
console-setup
kbd
# loadkeys is part of kbd — no separate package needed

# ── Storage / block ───────────────────────────────────────────────
# NVMe, SATA, USB storage — all kernel built-in on amd64.
# mdadm for RAID detection:
mdadm
# smartmontools for disk health:
smartmontools

# ── Boot ──────────────────────────────────────────────────────────
os-prober
grub2-common
grub-pc-bin
grub-efi-amd64-bin

# ── Terminal / UI ─────────────────────────────────────────────────
# Installer is TUI — no X needed
tmux
ncurses-bin

# ── seL4 build dependencies ───────────────────────────────────────
# Must be in the live ISO — cannot be fetched at install time
# if apt sources are limited
git
cmake
ninja-build
build-essential
gcc
g++
make
python3
python3-pip
python3-dev
python3-yaml
python3-jinja2
python3-ply
python3-lxml
libxml2-utils
device-tree-compiler
gnu-efi
efibootmgr

# ── Diagnostics ───────────────────────────────────────────────────
lshw
pciutils
fdisk
EOF

_ok "Package lists written."

# ── Copy installer scripts ────────────────────────────────────────
_step "Embedding installer scripts"

mkdir -p config/includes.chroot/installer
cp -r "${SCRIPT_DIR}/installer/"* config/includes.chroot/installer/
chmod +x config/includes.chroot/installer/*.sh

_ok "Installer scripts embedded."

# ── live-boot package (required for boot=live to work) ────────────
# Add to package list
echo "live-boot" >> config/package-lists/nexos-installer.list.chroot
echo "live-boot-initramfs-tools" >> config/package-lists/nexos-installer.list.chroot
# live-config intentionally excluded — it pulls in live-config-systemd on Devuan.
# Autologin is handled by the profile.d script instead.

# ── Kernel module pre-load hook ───────────────────────────────────
mkdir -p config/hooks/normal
cat > config/hooks/normal/0050-nexos-modules.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -e
# Ensure critical modules are available in the live env
# USB: xhci_hcd (USB3), ehci_hcd (USB2), ohci_hcd (USB1)
# HID: usbhid, hid_generic (keyboards/mice)
# Storage: usb_storage, uas (USB attached SCSI)
# NIC: r8169 (Realtek), e1000e (Intel), forcedeth (nForce)
# WiFi: iwlwifi, ath9k, ath10k_pci, brcmsmac, rtl8192ce
cat >> /etc/modules << EOF
xhci_hcd
ehci_hcd
ohci_hcd
usbhid
hid_generic
usb_storage
uas
r8169
e1000e
r8168
iwlwifi
iwl6000g2a
iwl6000g2b
ath9k
EOF
HOOKEOF
chmod +x config/hooks/normal/0050-nexos-modules.hook.chroot

# ── Console keyboard hook ─────────────────────────────────────────
cat > config/hooks/normal/0060-nexos-console.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -e
# Set default console keyboard layout
echo 'XKBLAYOUT="gb"' >> /etc/default/keyboard || true
# Reconfigure console-setup if available
dpkg-reconfigure -f noninteractive console-setup 2>/dev/null || true
HOOKEOF
chmod +x config/hooks/normal/0060-nexos-console.hook.chroot

# ── Auto-launch installer on boot ────────────────────────────────
_step "Configuring auto-launch"

# 1. Write inittab to autologin root on tty1 via a chroot hook
#    (inittab exists in the chroot because we install sysvinit-core)
mkdir -p config/hooks/normal
cat > config/hooks/normal/0070-nexos-autologin.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Replace tty1 getty with autologin getty
if [ -f /etc/inittab ]; then
    # Comment out existing tty1 line and add autologin version
    sed -i "s|^1:.*:respawn:.*tty1.*|#&|" /etc/inittab
    echo "1:2345:respawn:/sbin/agetty --autologin root --noclear tty1 38400 linux" >> /etc/inittab
fi
HOOKEOF
chmod +x config/hooks/normal/0070-nexos-autologin.hook.chroot

# 2. profile.d script launches installer once root is logged in
mkdir -p config/includes.chroot/etc/profile.d
cat > config/includes.chroot/etc/profile.d/nexos-installer.sh << 'EOF'
#!/bin/bash
# Auto-launch NexOS installer if running as root on console
if [ "$(id -u)" -eq 0 ] && [ -f /installer/install.sh ]; then
    # Use bash not exec so Ctrl+C drops back to this shell
    bash /installer/install.sh
    echo ""
    echo "Installer exited. You are now at a shell."
    echo "To restart: bash /installer/install.sh"
    echo "To view log: cat /tmp/nexos-install.log | tail -50"
fi
EOF
chmod +x config/includes.chroot/etc/profile.d/nexos-installer.sh

_ok "Auto-launch configured."

# ── GRUB config ───────────────────────────────────────────────────
_step "Configuring GRUB menu"

mkdir -p config/bootloaders/grub-pc
mkdir -p config/bootloaders/grub-efi

cat > config/bootloaders/grub-pc/grub.cfg << 'EOF'
set default=0
set timeout=5

if background_image /boot/grub/background.png; then
    set color_normal=cyan/black
    set color_highlight=white/cyan
fi

# Use search to find the versioned kernel and initrd automatically
set default=0
set timeout=5

if background_image /boot/grub/background.png; then
    set color_normal=cyan/black
    set color_highlight=white/cyan
fi

# KERNEL PATH FIX — DO NOT REMOVE
# grub.cfg uses UNVERSIONED /live/vmlinuz and /live/initrd.img.
# The binary hook below copies the versioned kernel to these names,
# so kernel updates can never break the ISO boot.

menuentry "NexOS Installer" {
    search --no-floppy --label --set=root NexOS-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer quiet
    initrd ($root)/live/initrd.img
}

menuentry "NexOS Installer (nomodeset)" {
    search --no-floppy --label --set=root NexOS-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer nomodeset
    initrd ($root)/live/initrd.img
}

menuentry "NexOS Installer (safe mode)" {
    search --no-floppy --label --set=root NexOS-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer noapic noacpi nomodeset
    initrd ($root)/live/initrd.img
}
EOF

cp config/bootloaders/grub-pc/grub.cfg config/bootloaders/grub-efi/grub.cfg

# Copy GRUB background from branding folder if present
mkdir -p config/bootloaders/grub-pc
mkdir -p config/bootloaders/grub-efi
BRANDING_IMG="${SCRIPT_DIR}/branding/grub-background.png"
if [[ -f "$BRANDING_IMG" ]]; then
    cp "$BRANDING_IMG" config/bootloaders/grub-pc/background.png
    cp "$BRANDING_IMG" config/bootloaders/grub-efi/background.png
    # Also embed in the live filesystem so grub finds it at boot
    mkdir -p config/includes.chroot/boot/grub
    cp "$BRANDING_IMG" config/includes.chroot/boot/grub/background.png
    _ok "GRUB background: ${BRANDING_IMG}"
else
    _info "No branding/grub-background.png found — GRUB will use default background."
    _info "Place a PNG at: ${SCRIPT_DIR}/branding/grub-background.png"
fi

_ok "GRUB config written."

# Add a binary hook to rewrite grub.cfg with the actual kernel filename
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-fix-grub-kernel.hook.binary << 'HOOKEOF'
#!/bin/sh
# KERNEL PATH FIX — DO NOT REMOVE
# Binary hooks run with cwd = the ISO binary/ directory.
# Copy the versioned kernel/initrd to unversioned names so the
# grub.cfg /live/vmlinuz and /live/initrd.img paths always work.
set -e
VMLINUZ=$(ls live/vmlinuz-* 2>/dev/null | sort | tail -1)
INITRD=$(ls live/initrd.img-* 2>/dev/null | sort | tail -1)
if [ -n "$VMLINUZ" ]; then
    cp "$VMLINUZ" live/vmlinuz
    echo "Copied $VMLINUZ -> live/vmlinuz"
else
    echo "WARNING: no live/vmlinuz-* found in $(pwd)"
    ls live/ || true
fi
if [ -n "$INITRD" ]; then
    cp "$INITRD" live/initrd.img
    echo "Copied $INITRD -> live/initrd.img"
fi
HOOKEOF
chmod +x config/hooks/normal/9999-fix-grub-kernel.hook.binary

# ── Build ─────────────────────────────────────────────────────────
_step "Building ISO (this will take a while...)"

LB_LOG="${BUILD_DIR}/lb-build.log"
lb build 2>&1 | tee "$LB_LOG" | while IFS= read -r line; do
    echo "  ${line}"
done
# tee exits 0 — check the log for lb failure marker instead
if grep -qE "^E:|^lb build failed" "$LB_LOG" 2>/dev/null; then
    _die "live-build failed. Check ${LB_LOG}"
fi
# Also verify the ISO was actually produced
if [[ ! -f "${BUILD_DIR}/live-image-amd64.hybrid.iso" ]] &&    ! find "${BUILD_DIR}" -name "*.iso" | grep -q .; then
    _die "live-build produced no ISO. Check ${LB_LOG}"

# Post-build safety net: verify unversioned kernel exists in the binary tree
# (in case the binary hook did not run). If missing, add it and regenerate ISO.
BIN_LIVE="${BUILD_DIR}/binary/live"
if [[ -d "$BIN_LIVE" ]] && [[ ! -f "${BIN_LIVE}/vmlinuz" ]]; then
    _info "Hook missed — copying unversioned kernel into ISO tree..."
    VK=$(ls "${BIN_LIVE}"/vmlinuz-* 2>/dev/null | sort | tail -1)
    VI=$(ls "${BIN_LIVE}"/initrd.img-* 2>/dev/null | sort | tail -1)
    [[ -n "$VK" ]] && cp "$VK" "${BIN_LIVE}/vmlinuz"
    [[ -n "$VI" ]] && cp "$VI" "${BIN_LIVE}/initrd.img"
    # Rebuild the ISO image with the added files
    FOUND_ISO_TEMP=$(find "${BUILD_DIR}" -name "*.iso" 2>/dev/null | head -1)
    if [[ -n "$FOUND_ISO_TEMP" ]] && command -v xorriso &>/dev/null; then
        _info "Injecting unversioned kernel into existing ISO..."
        xorriso -boot_image any keep \
            -dev "$FOUND_ISO_TEMP" \
            -map "${BIN_LIVE}/vmlinuz" /live/vmlinuz \
            -map "${BIN_LIVE}/initrd.img" /live/initrd.img \
            2>&1 | grep -v "^xorriso :" || true
        _ok "Kernel injected into ISO."
    fi
fi

# Post-process ISO for Rufus/Windows compatibility
_step "Making ISO Rufus-compatible"
FOUND_ISO_TEMP=$(find "${BUILD_DIR}" -name "*.iso" 2>/dev/null | head -1)
if [[ -n "$FOUND_ISO_TEMP" ]]; then
    if command -v isohybrid &>/dev/null; then
        isohybrid --uefi "$FOUND_ISO_TEMP" 2>/dev/null || \
            isohybrid "$FOUND_ISO_TEMP" 2>/dev/null || true
        _ok "isohybrid applied — Rufus compatible."
    else
        _info "isohybrid not found. Installing syslinux-utils..."
        apt-get install -y syslinux-utils &>/dev/null && \
            isohybrid --uefi "$FOUND_ISO_TEMP" 2>/dev/null || true
    fi
fi

fi

# ── Copy output ───────────────────────────────────────────────────
_step "Finalising"

FOUND_ISO=$(find "${BUILD_DIR}" -name "*.hybrid.iso" | head -1)
if [[ -z "$FOUND_ISO" ]]; then
    FOUND_ISO=$(find "${BUILD_DIR}" -name "*.iso" | head -1)
fi

if [[ -z "$FOUND_ISO" ]]; then
    _die "ISO not found in build output."
fi

cp "$FOUND_ISO" "$OUTPUT_ISO"
_ok "ISO written: ${OUTPUT_ISO}"

SIZE=$(du -sh "$OUTPUT_ISO" | cut -f1)
echo ""
echo "  ══════════════════════════════════════════"
echo "  NexOS Installer ISO built successfully"
echo "  Output: ${OUTPUT_ISO}"
echo "  Size:   ${SIZE}"
echo "  ══════════════════════════════════════════"
echo ""
echo "  Write to USB:"
echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo "    sudo sync"
echo ""
