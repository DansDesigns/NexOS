#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install.sh — NexOS Net Installer
#
# Flow:
#   welcome → hardware → network → user config → disk →
#   base install → seL4 → desktop → system config →
#   bootloader → done
#
# Requires: root, internet connection, 8 GB+ free disk
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
# Note: -e intentionally omitted — each stage handles its own errors
# so a non-fatal warning doesn't kill the whole installer.

# Check if user deliberately dropped to shell — do not restart
if [[ -f /tmp/.nexos-shell-drop ]]; then
    # Stay silent — the shell is already running
    exit 0
fi

# Prevent re-entry if already running
if [[ -f /tmp/.nexos-installer-running ]]; then
    echo ""
    echo "Installer already ran. Type: install   to restart."
    exit 0
fi
touch /tmp/.nexos-installer-running

# Easy restart alias — just type: install
cat > /usr/local/bin/install << 'ALIAS'
#!/bin/bash
rm -f /tmp/.nexos-installer-running
exec bash /installer/install.sh
ALIAS
chmod +x /usr/local/bin/install

# Ctrl+C drops to shell cleanly — kill spinner then exit to shell
trap '_nexos_interrupted' INT

_nexos_interrupted() {
    spin_stop 2>/dev/null || true
    echo ""
    echo ""
    echo -e "  ${Y}Installer interrupted.${N}"
    echo -e "  Type ${W}install${N} to restart."
    rm -f /tmp/.nexos-installer-running
    trap - INT EXIT
    # Return to shell by ending this script without re-exec
    exit 0
}

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NEXOS_MOUNT="/mnt/nexos"
export NEXOS_LOG="/tmp/nexos-install.log"

# Tee all output to log file so errors are never lost
exec > >(tee -a "$NEXOS_LOG") 2>&1
echo "=== NexOS Installer started $(date) ==="

# Stop kernel messages (e.g. PCIe AER spam) flooding the installer TUI
dmesg -n 1 2>/dev/null || true

# Flag to suppress screen clear after errors
NEXOS_ERROR_SHOWN=0

# ── Source modules ────────────────────────────────────────────────
source "${INSTALLER_DIR}/ui.sh"
export NEXOS_ERROR_COUNT=0


source "${INSTALLER_DIR}/hardware-detect.sh"
source "${INSTALLER_DIR}/network.sh"
source "${INSTALLER_DIR}/partition.sh"
source "${INSTALLER_DIR}/install_base.sh"
source "${INSTALLER_DIR}/build_sel4.sh"
source "${INSTALLER_DIR}/configure_system.sh"
source "${INSTALLER_DIR}/install_desktop.sh"

# ── Root check ────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash install.sh"
    exit 1
fi

# ── Trap: cleanup mounts on unexpected exit ───────────────────────
trap '_on_exit' EXIT

_show_menu() {
    local title="${1:-What would you like to do?}"
    echo ""
    echo "$title"
    echo ""
    echo "  1  Restart installer"
    echo "  2  Drop to shell"
    echo "  3  Shutdown"
    echo "  4  Reboot"
    echo "  5  View logs"
    echo ""
}

_nexos_pager() {
    # Pure-bash scrollable pager — no less/more needed.
    # Use the whole screen: release the banner scroll region first.
    printf '\033[r' 
    # Keys: Up/Down arrows, PgUp/PgDn, Home/End, q to quit.
    local file="$1"
    local -a plines
    mapfile -t plines < "$file"
    local total=${#plines[@]}
    local rows=$(( $(stty size 2>/dev/null | cut -d' ' -f1 || echo 24) - 2 ))
    (( rows < 5 )) && rows=22
    local max_top=$(( total - rows ))
    (( max_top < 0 )) && max_top=0
    # Start at the END — the most recent output is what matters
    local top=$max_top

    while true; do
        clear
        local i
        for (( i=top; i<top+rows && i<total; i++ )); do
            printf '%s\n' "${plines[$i]}"
        done
        printf '\033[7m -- line %d-%d of %d  [arrows/PgUp/PgDn/Home/End scroll, q quit] --\033[0m' \
            $((top+1)) $(( top+rows<total ? top+rows : total )) "$total"

        IFS= read -rsn1 key
        if [[ "$key" == $'\033' ]]; then
            read -rsn2 -t 0.05 key2
            case "$key2" in
                '[A') (( top>0 )) && (( top-- )) ;;                    # Up
                '[B') (( top<max_top )) && (( top++ )) ;;              # Down
                '[5') read -rsn1 -t 0.05 _; top=$(( top-rows ));       # PgUp
                      (( top<0 )) && top=0 ;;
                '[6') read -rsn1 -t 0.05 _; top=$(( top+rows ));       # PgDn
                      (( top>max_top )) && top=$max_top ;;
                '[H') top=0 ;;                                         # Home
                '[F') top=$max_top ;;                                  # End
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            break
        elif [[ -z "$key" ]]; then
            # ENTER: scroll one line
            (( top<max_top )) && (( top++ ))
        fi
    done
    clear
}

_show_logs() {
    local tmp="/tmp/.nexos-logview"
    {
        echo "=== /tmp/nexos-install.log ==="
        cat /tmp/nexos-install.log 2>/dev/null || echo "(no install log)"
        if [ -s /tmp/sel4-cmake.log ]; then
            echo ""
            echo "=== /tmp/sel4-cmake.log ==="
            cat /tmp/sel4-cmake.log
        fi
    } > "$tmp"
    _nexos_pager "$tmp"
    rm -f "$tmp"
}

_on_exit() {
    rm -f /tmp/.nexos-installer-running
    local code=$?
    if [[ $code -ne 0 ]]; then
        NEXOS_ERROR_SHOWN=1
        spin_stop 2>/dev/null || true
        echo ""
        echo -e "\033[0;31m╔══════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[0;31m║  INSTALLER ERROR — exit code ${code}                \033[0m"
        echo -e "\033[0;31m╚══════════════════════════════════════════════════╝\033[0m"
        echo ""
        err "Installer exited unexpectedly (code ${code})."
        echo ""
        # Show last 25 lines of log immediately on screen
        if [[ -f "$NEXOS_LOG" ]]; then
            echo -e "  ${Y}=== Last 25 lines of install log ===${N}"
            echo ""
            cat "$NEXOS_LOG" | while IFS= read -r l; do echo "  $l"; done
            echo ""
        fi
        info "Cleaning up mounts..."
        cleanup_mounts 2>/dev/null || true
        echo ""
        echo -e "  ${T}Full log: ${NEXOS_LOG}${N}"
        echo ""

        _show_menu
        while true; do
            echo -en "  ${W}Choice${N}: "
            IFS= read -r choice
            case "$choice" in
                1) rm -f /tmp/.nexos-installer-running; exec bash /installer/install.sh ;;
                2) rm -f /tmp/.nexos-installer-running
                   touch /tmp/.nexos-shell-drop
                   echo ""
                   echo " NexOS Shell — type: install  to restart"
                   echo ""
                   printf '\033[r'
           env PS1="[nexos]: " /bin/bash --norc -i
                   rm -f /tmp/.nexos-shell-drop
                   exit 0 ;;
                3) printf '\033[r'; sync; /sbin/poweroff -f ;;
                4) printf '\033[r'; sync; /sbin/reboot -f ;;
                5) _show_logs
                   # Redraw menu after returning from logs
                   echo ""
                   echo -e "  ${W}What would you like to do?${N}"
                   echo ""
                   echo -e "  ${T}1${N}  Restart installer"
                   echo -e "  ${T}2${N}  Drop to shell"
                   echo -e "  ${T}3${N}  Shutdown"
                   echo -e "  ${T}4${N}  Reboot"
                   echo -e "  ${T}5${N}  View logs"
                   echo "" ;;
                ""|$'
') ;;
                *) warn "Enter 1-5." ;;
            esac
        done
    fi
}

# ════════════════════════════════════════════════════════════════
# STAGE 1: Welcome
# ════════════════════════════════════════════════════════════════
banner

echo -e "  ${W}Welcome to NexOS.${N}"
echo ""
echo -e "  This installer will:"
echo ""
echo -e "    ${T}1${N}  Detect your hardware"
echo -e "    ${T}2${N}  Connect to the internet"
echo -e "    ${T}3${N}  Collect your preferences (user, disk, locale)"
echo -e "    ${T}4${N}  Partition and format your disk"
echo -e "    ${T}5${N}  Install Devuan base + OpenRC (no systemd)"
echo -e "    ${T}6${N}  Build the seL4 microkernel"
echo -e "    ${T}7${N}  Install your chosen desktop environment"
echo -e "    ${T}8${N}  Configure and boot"
echo ""
echo -e "  ${D}Estimated time:  30–50 minutes (seL4 build included)${N}"
echo -e "  ${D}Requires:        internet connection · 8 GB+ free disk${N}"
echo ""

if ! confirm "Begin installation?"; then
    echo ""
    echo -e "  ${W}What would you like to do?${N}"
    echo ""
    echo -e "  ${T}1${N}  Restart installer"
    echo -e "  ${T}2${N}  Drop to shell"
    echo -e "  ${T}3${N}  Shutdown"
    echo -e "  ${T}4${N}  Reboot"
    echo -e "  ${T}5${N}  View logs"
    echo ""
    while true; do
        echo -en "  ${W}Choice${N}: "
        IFS= read -r choice
        case "$choice" in
            1) rm -f /tmp/.nexos-installer-running; exec bash /installer/install.sh ;;
            2) rm -f /tmp/.nexos-installer-running
               echo -e "  Type ${W}install${N} to restart."
               trap - INT EXIT; exit 0 ;;
            3) printf '\033[r'; sync; /sbin/poweroff -f ;;
            4) printf '\033[r'; sync; /sbin/reboot -f ;;
            5) _show_logs
               echo ""
               echo -e "  ${W}What would you like to do?${N}"
               echo ""
               echo -e "  ${T}1${N}  Restart installer"
               echo -e "  ${T}2${N}  Drop to shell"
               echo -e "  ${T}3${N}  Shutdown"
               echo -e "  ${T}4${N}  Reboot"
               echo -e "  ${T}5${N}  View logs"
               echo "" ;;
            *) warn "Enter 1-5." ;;
        esac
    done
fi

# ════════════════════════════════════════════════════════════════
# STAGE 2: Hardware Detection
# ════════════════════════════════════════════════════════════════
detect_hardware
show_hardware

press_any_key

# ════════════════════════════════════════════════════════════════
# STAGE 3: Network
# ════════════════════════════════════════════════════════════════
banner
progress_set 1 "Network"
banner
setup_network

# Fix wrong RTC before any TLS (git/apt) — see net_sync_clock
net_sync_clock

# ════════════════════════════════════════════════════════════════
# STAGE 4: Gather config (user + disk preferences)
# before touching anything on disk
# ════════════════════════════════════════════════════════════════
banner
progress_set 2 "User config"
banner
gather_user_config

# ════════════════════════════════════════════════════════════════
# STAGE 5: Disk
# ════════════════════════════════════════════════════════════════
banner
progress_set 3 "Disk setup"
banner
setup_disk

# ════════════════════════════════════════════════════════════════
# STAGE 6: Base System
# ════════════════════════════════════════════════════════════════
banner
progress_set 4 "Base system"
banner
install_base

# ════════════════════════════════════════════════════════════════
# STAGE 7: seL4
# ════════════════════════════════════════════════════════════════
banner
progress_set 5 "seL4 kernel"
banner
build_sel4

# ════════════════════════════════════════════════════════════════
# STAGE 9: Configure System
# ════════════════════════════════════════════════════════════════
banner
progress_set 7 "Configuring"
banner
configure_system

# ════════════════════════════════════════════════════════════════
# STAGE 9b: Desktop Environment
# Runs AFTER Devuan base + seL4 + system config are complete.
# Selection happens here too, then installs immediately.
# ════════════════════════════════════════════════════════════════
progress_set 8 "Desktop"
banner
select_desktop
banner
install_desktop

# ════════════════════════════════════════════════════════════════
# STAGE 10: Done
# ════════════════════════════════════════════════════════════════
banner

echo -e "  ${G}Installation complete.${N}"
echo ""
echo -e "  ${W}Installed to:${N}  ${TARGET_DISK}"
echo -e "  ${W}Hostname:${N}      ${NEXOS_HOSTNAME}"
echo -e "  ${W}User:${N}          ${NEXOS_USERNAME}"
echo -e "  ${W}Arch:${N}          ${HW_ARCH}"
echo ""
echo -e "  ${D}Remove the installation media and reboot.${N}"

# Verify bootloader was installed
if [[ -f "${NEXOS_MOUNT}/boot/grub/grub.cfg" ]]; then
    ok "grub.cfg found — bootloader installed correctly."
else
    warn "grub.cfg NOT found — system may not boot!"
    warn "Check: ls ${NEXOS_MOUNT}/boot/"
    ls "${NEXOS_MOUNT}/boot/" 2>/dev/null | while IFS= read -r f; do warn "  $f"; done
fi

echo ""

cleanup_mounts

rm -f /tmp/.nexos-installer-running
echo -e "  ${W}What would you like to do?${N}"
echo ""
echo -e "  ${T}1${N}  Reboot"
echo -e "  ${T}2${N}  Drop to shell (inspect before rebooting)"
echo -e "  ${T}3${N}  View install log"
echo -e "  ${T}4${N}  Shutdown"
echo ""
while true; do
    echo -en "  ${W}Choice${N}: "
    IFS= read -r choice
    case "$choice" in
        1) printf '\033[r'; sync; /sbin/reboot -f ;;
        2) rm -f /tmp/.nexos-installer-running
           touch /tmp/.nexos-shell-drop
           echo ""
           echo " NexOS Shell — type: install  to restart"
           echo " System at: ${NEXOS_MOUNT}"
           echo " Grub: ls ${NEXOS_MOUNT}/boot/grub/"
           echo " Log:  cat /tmp/nexos-install.log"
           echo ""
           printf '\033[r'
           env PS1="[nexos]: " /bin/bash --norc -i
           rm -f /tmp/.nexos-shell-drop
           exit 0 ;;
        3) _show_logs
           echo ""
           echo -e "  ${T}1${N}  Reboot"
           echo -e "  ${T}2${N}  Drop to shell (inspect before rebooting)"
           echo -e "  ${T}3${N}  View install log"
           echo -e "  ${T}4${N}  Shutdown"
           echo "" ;;
        4) printf '\033[r'; sync; /sbin/poweroff -f ;;
        ""|$'
') ;;
        *) warn "Enter 1-4." ;;
    esac
done
