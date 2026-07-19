#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_desktop.sh — NexOS Desktop Environment Installation
# ═══════════════════════════════════════════════════════════════

NEXOS_DESKTOP=""

# ── Desktop selection TUI ─────────────────────────────────────────
select_desktop() {
    section "Desktop Environment"

    echo -e "  ${W}Choose a desktop environment:${N}"
    echo ""
    echo -e "  ${T} 1${N}  ${W}Alternix${N}          ${D}NexOS native DE (from GitHub)${N}"
    echo -e "  ${T} 2${N}  ${W}XFCE${N}              ${D}Lightweight, traditional${N}"
    echo -e "  ${T} 3${N}  ${W}LXQt${N}              ${D}Lightweight Qt-based${N}"
    echo -e "  ${T} 4${N}  ${W}LXDE${N}              ${D}Very lightweight GTK2${N}"
    echo -e "  ${T} 5${N}  ${W}MATE${N}              ${D}Classic GNOME2 fork${N}"
    echo -e "  ${T} 6${N}  ${W}Openbox${N}           ${D}Minimal window manager only${N}"
    echo -e "  ${T} 7${N}  ${W}CLI only${N}          ${D}No desktop — terminal only${N}"
    echo ""

    while true; do
        echo -en "  ${W}Select${N} ${D}[1]${N}: "
        read -r choice
        case "$choice" in
            ""|1) NEXOS_DESKTOP="alternix" ;;
            2) NEXOS_DESKTOP="xfce" ;;
            3) NEXOS_DESKTOP="lxqt" ;;
            4) NEXOS_DESKTOP="lxde" ;;
            5) NEXOS_DESKTOP="mate" ;;
            6) NEXOS_DESKTOP="openbox" ;;
            7) NEXOS_DESKTOP="cli" ;;
            *) warn "Enter 1-7."; continue ;;
        esac
        break
    done

    echo ""
    case "$NEXOS_DESKTOP" in
        alternix) info "Alternix will be cloned from GitHub and built." ;;
        cli)      info "CLI only — no display server or desktop will be installed." ;;
        *)        info "$(echo $NEXOS_DESKTOP | tr '[:lower:]' '[:upper:]') will be installed from Devuan repos." ;;
    esac
    echo ""
    confirm "Install ${NEXOS_DESKTOP}?" || select_desktop
}

# ── Main desktop install entrypoint ──────────────────────────────
install_desktop() {
    # SAFETY NET — DO NOT REMOVE
    # If the desktop was somehow never selected, ask now rather than
    # silently skipping (a user must NEVER end up without a GUI).
    if [[ -z "${NEXOS_DESKTOP:-}" ]]; then
        warn "No desktop was selected earlier — choose one now."
        select_desktop
    fi

    echo ""
    echo -e "  ${T}═══════════════════════════════════════════${N}"
    echo -e "  ${W}  INSTALLING DESKTOP: ${NEXOS_DESKTOP}${N}"
    echo -e "  ${T}═══════════════════════════════════════════${N}"
    echo ""

    # CHROOT PREP — DO NOT REMOVE
    # Every desktop path needs /proc /sys /dev /dev/pts mounted
    # (bind of /dev is NOT recursive — pts must be bound separately)
    # and DNS via resolv.conf, for apt and git inside the chroot.
    for fs in proc sys dev dev/pts; do
        mkdir -p "${NEXOS_MOUNT}/${fs}"
        mount --bind "/${fs}" "${NEXOS_MOUNT}/${fs}" 2>/dev/null || true
    done
    cp /etc/resolv.conf "${NEXOS_MOUNT}/etc/resolv.conf" 2>/dev/null || true

    case "$NEXOS_DESKTOP" in
        alternix) _install_alternix ;;
        xfce)     _install_xfce ;;
        lxqt)     _install_lxqt ;;
        lxde)     _install_lxde ;;
        mate)     _install_mate ;;
        openbox)  _install_openbox ;;
        cli)      _install_cli ;;
        *)        err "Unknown desktop value: '${NEXOS_DESKTOP}'"
                  warn "Re-running desktop selection..."
                  select_desktop
                  install_desktop ;;
    esac

    # Unmount chroot filesystems
    for fs in dev/pts dev sys proc; do
        umount "${NEXOS_MOUNT}/${fs}" 2>/dev/null || true
    done
}

# ── Shared X11 base ───────────────────────────────────────────────
_install_xbase() {
    info "Installing X11 base..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        xorg xserver-xorg xinit x11-utils x11-xserver-utils \
        xterm fonts-noto fonts-liberation \
        dbus-x11 at-spi2-core \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done
    ok "X11 base installed."
}

_chroot() {
    chroot "$NEXOS_MOUNT" /bin/bash -c "$*"
}

# ── Alternix ──────────────────────────────────────────────────────
_install_alternix() {
    section "Installing Alternix Desktop"

    step 1 3 "Installing git in the target system..."
    # GIT IN TARGET — DO NOT REMOVE
    # git exists in the live env (seL4 uses it) but the Alternix clone
    # runs INSIDE the chroot, so the target needs its own git.
    _chroot "apt-get update -qq" 2>&1 | tee -a "$NEXOS_LOG" || true
    _chroot "apt-get install -y git ca-certificates" 2>&1 | tee -a "$NEXOS_LOG"
    # (test the binary directly — 'command -v' is a shell builtin and
    #  cannot be exec'd by chroot)
    if [[ ! -x "${NEXOS_MOUNT}/usr/bin/git" && ! -x "${NEXOS_MOUNT}/bin/git" ]]; then
        err "git could not be installed in the target — cannot clone Alternix."
        err "apt output above shows why (check sources/network)."
        return 1
    fi
    ok "git present in target."

    step 2 3 "Cloning Alternix repository..."
    if chroot "$NEXOS_MOUNT" git clone --depth=1 \
        https://github.com/DansDesigns/Alternix.git \
        "/home/${NEXOS_USERNAME}/Alternix" \
        2>&1 | tee -a "$NEXOS_LOG"; then
        ok "Alternix cloned."
    else
        err "Failed to clone Alternix — check network."
        return 1
    fi
    _chroot "chown -R ${NEXOS_USERNAME}:${NEXOS_USERNAME} /home/${NEXOS_USERNAME}/Alternix"

    # osm-sudo: make the GUI pattern-auth wrapper available system-wide,
    # and export SUDO_ASKPASS so apps using 'sudo -A' get the GUI prompt.
    if [[ -f "/home/${NEXOS_USERNAME}/Alternix/osm-sudo" ]] || \
       [[ -f "${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/Alternix/osm-sudo" ]]; then
        local osm_src="${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/Alternix/osm-sudo"
        [[ -f "$osm_src" ]] || osm_src="/home/${NEXOS_USERNAME}/Alternix/osm-sudo"
        tr -d '\r' < "$osm_src" > "${NEXOS_MOUNT}/usr/local/bin/osm-sudo"
        chmod +x "${NEXOS_MOUNT}/usr/local/bin/osm-sudo"
        cat > "${NEXOS_MOUNT}/etc/profile.d/osm-sudo.sh" << 'OSMEOF'
# Alternix GUI sudo: apps calling "sudo -A" get the osm-lock pattern prompt
export SUDO_ASKPASS=/usr/local/bin/osm-sudo
OSMEOF
        ok "osm-sudo installed to /usr/local/bin (CRLF stripped)."
    fi

    step 3 3 "Running the Alternix installer..."
    echo ""

    # ═══════════════════════════════════════════════════════════
    # DEBCONF PRESEED — DO NOT REMOVE
    # keyboard-configuration / console-setup pop broken TUIs inside
    # the chroot. Pre-answer them from the locale chosen in the
    # NexOS installer, and export DEBIAN_FRONTEND=noninteractive
    # for the run (env only — the Alternix script is NOT modified).
    # ═══════════════════════════════════════════════════════════
    local kb_layout
    case "${NEXOS_LOCALE:-en_GB.UTF-8}" in
        en_GB*) kb_layout="gb" ;;
        en_US*) kb_layout="us" ;;
        de_DE*) kb_layout="de" ;;
        fr_FR*) kb_layout="fr" ;;
        *)      kb_layout="us" ;;
    esac

    chroot "$NEXOS_MOUNT" debconf-set-selections << DEBEOF
keyboard-configuration  keyboard-configuration/xkb-keymap       select  ${kb_layout}
keyboard-configuration  keyboard-configuration/layoutcode       string  ${kb_layout}
keyboard-configuration  keyboard-configuration/variant          select  ${kb_layout}
keyboard-configuration  keyboard-configuration/model            select  pc105
console-setup           console-setup/charmap47                 select  UTF-8
console-setup           console-setup/codeset47                 select  Guess optimal character set
DEBEOF

    # Write the keyboard config file directly too
    cat > "${NEXOS_MOUNT}/etc/default/keyboard" << KBEOF
XKBMODEL="pc105"
XKBLAYOUT="${kb_layout}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBEOF

    info "Keyboard preseeded: ${kb_layout} (from ${NEXOS_LOCALE})"
    info "The Alternix installer will now run. Answer its prompts when asked."
    echo ""

    # Run interactively — direct terminal, no pipes, so prompts work.
    # DEBIAN_FRONTEND=noninteractive stops debconf TUIs opening.
    chroot "$NEXOS_MOUNT" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        DEBCONF_NONINTERACTIVE_SEEN=true \
        HOME="/home/${NEXOS_USERNAME}" \
        /bin/bash -c \
        "cd /home/${NEXOS_USERNAME}/Alternix && \
         bash install-alternix_devuan.sh"
    local alt_exit=$?

    if [[ $alt_exit -eq 0 ]]; then
        ok "Alternix installed — system will boot into the desktop."
    else
        warn "Alternix installer exited with code ${alt_exit}."
        warn "Check output above for details."
    fi
}

# ── XFCE ──────────────────────────────────────────────────────────
_install_xfce() {
    step 1 2 "Installing XFCE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "XFCE installed."
}

# ── LXQt ──────────────────────────────────────────────────────────
_install_lxqt() {
    step 1 2 "Installing LXQt..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lxqt sddm xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add sddm default" &>/dev/null || true
    ok "LXQt installed."
}

# ── LXDE ──────────────────────────────────────────────────────────
_install_lxde() {
    step 1 2 "Installing LXDE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lxde lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "LXDE installed."
}

# ── MATE ──────────────────────────────────────────────────────────
_install_mate() {
    step 1 2 "Installing MATE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mate-desktop-environment lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "MATE installed."
}

# ── Openbox ───────────────────────────────────────────────────────
_install_openbox() {
    step 1 2 "Installing Openbox..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        openbox obconf obmenu \
        xorg dbus-x11 fonts-noto \
        tint2 nitrogen rofi dunst \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Configuring Openbox autostart..."
    mkdir -p "${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/.config/openbox"
    cat > "${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/.xinitrc" << 'EOF'
#!/bin/sh
exec openbox-session
EOF
    chmod +x "${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/.xinitrc"
    _chroot "chown -R ${NEXOS_USERNAME}:${NEXOS_USERNAME} /home/${NEXOS_USERNAME}"
    _write_autologin "startx"
    ok "Openbox installed."
}

# ── CLI only ──────────────────────────────────────────────────────
_install_cli() {
    info "CLI mode — no desktop installed."
    info "Install a desktop later with: apt-get install xfce4"

    # Nice CLI tools
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        tmux mc ranger bat fd-find ripgrep \
        2>&1" | tee -a "$NEXOS_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    ok "CLI environment ready."
}

# ── Autologin helper ──────────────────────────────────────────────
_write_autologin() {
    local start_cmd="$1"

    # Write getty autologin for tty1
    mkdir -p "${NEXOS_MOUNT}/etc/inittab.d" 2>/dev/null || true

    # Patch inittab for autologin on tty1
    if [[ -f "${NEXOS_MOUNT}/etc/inittab" ]]; then
        sed -i "s|^1:.*tty1.*|1:2345:respawn:/sbin/agetty --autologin ${NEXOS_USERNAME} --noclear tty1 38400 linux|" \
            "${NEXOS_MOUNT}/etc/inittab"
    fi

    # Write .bash_profile to auto-startx on login
    cat > "${NEXOS_MOUNT}/home/${NEXOS_USERNAME}/.bash_profile" << EOF
# Auto-start desktop on tty1 login
if [[ -z "\$DISPLAY" ]] && [[ "\$(tty)" == "/dev/tty1" ]]; then
    ${start_cmd}
fi
EOF
    _chroot "chown ${NEXOS_USERNAME}:${NEXOS_USERNAME} /home/${NEXOS_USERNAME}/.bash_profile"
    ok "Autologin configured for ${NEXOS_USERNAME} → ${start_cmd}"
}
