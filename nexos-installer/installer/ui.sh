#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ui.sh — NexOS Installer UI helpers
# ═══════════════════════════════════════════════════════════════

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'
M='\033[0;35m'; C='\033[0;36m'; W='\033[1;37m'; D='\033[0;37m'
T='\033[0;36m'; N='\033[0m'

# ── Overall install progress ──────────────────────────────────────
INSTALL_TOTAL_STEPS=8
INSTALL_CURRENT_STEP=0
INSTALL_STEP_NAME=""

progress_set() {
    INSTALL_CURRENT_STEP=$1
    INSTALL_STEP_NAME="$2"
}

_draw_overall_bar() {
    local width=34
    local filled=$(( INSTALL_CURRENT_STEP * width / INSTALL_TOTAL_STEPS ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    local pct=$(( INSTALL_CURRENT_STEP * 100 / INSTALL_TOTAL_STEPS ))
    echo -e "  ${T}[${bar}]${N} ${W}${pct}%${N}  ${D}${INSTALL_STEP_NAME:-starting...}${N}"
    echo ""
}

# ── Banner with live system specs ────────────────────────────────
# STATIC BANNER — DO NOT REMOVE
# The banner occupies the top 16 lines; an ANSI scroll region (ESC[17;Nr)
# confines all further console output BELOW it, so new text can never
# push the banner off-screen.
NEXOS_BANNER_LINES=16

banner() {
    # Do not clear screen if an error is currently displayed
    if [[ "${NEXOS_ERROR_SHOWN:-0}" -eq 1 ]]; then
        return 0
    fi
    # Reset any previous scroll region, then clear
    printf '\033[r'
    clear
    local cpu ram arch
    cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' | sed 's/  */ /g' | cut -c1-36 || echo "Unknown")
    ram=$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    arch=$(uname -m 2>/dev/null || echo "?")

    echo -e "${T}"
    echo "  ███╗   ██╗███████╗██╗  ██╗ ██████╗ ███████╗"
    echo "  ████╗  ██║██╔════╝╚██╗██╔╝██╔═══██╗██╔════╝"
    echo "  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║███████╗"
    echo "  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║╚════██║"
    echo "  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝███████║"
    echo "  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝"
    echo -e "${N}"
    echo -e "  ${W}NexOS Installer v0.1${N}  ${D}One OS. Any machine.${N}"
    echo ""
    echo -e "  ${D}CPU   ${N}${W}${cpu}${N}"
    echo -e "  ${D}RAM   ${N}${W}${ram}${N}   ${D}Arch${N} ${W}${arch}${N}"
    local _ec=${NEXOS_ERROR_COUNT:-0}
    if [[ $_ec -gt 0 ]]; then
        printf "  ${R}Errors Encountered: %02d${N}\n" "$_ec"
    else
        echo -e "  ${G}Errors Encountered: 00${N}"
    fi
    echo ""
    _draw_overall_bar

    # Lock the header: scrolling only happens below line NEXOS_BANNER_LINES
    local _rows
    _rows=$(stty size 2>/dev/null | cut -d' ' -f1)
    [[ -z "$_rows" || "$_rows" -le $(( NEXOS_BANNER_LINES + 4 )) ]] && _rows=24
    printf '\033[%d;%dr' $(( NEXOS_BANNER_LINES + 1 )) "$_rows"
    printf '\033[%d;1H' $(( NEXOS_BANNER_LINES + 1 ))
}

section() {
    echo ""
    echo -e "  ${T}══  ${W}$1${T}  ══${N}"
    echo ""
}

info()  { echo -e "  ${D}·${N} $1"; }
ok()    { echo -e "  ${G}✓${N} $1"; }
warn()  { echo -e "  ${Y}!${N} $1"; }
err()   { NEXOS_ERROR_COUNT=$(( ${NEXOS_ERROR_COUNT:-0} + 1 )); echo -e "  ${R}✗${N} $1"; }
die()   { err "$1"; echo ""; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    while true; do
        echo -en "  ${W}${msg}${N} ${D}[y/n]${N} "
        read -r ans
        case "$ans" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
            *) warn "Please enter y or n." ;;
        esac
    done
}

prompt_input() {
    local -n _ref=$1
    local msg="$2" default="${3:-}" hint=""
    [[ -n "$default" ]] && hint=" ${D}[${default}]${N}"
    while true; do
        echo -en "  ${W}${msg}${N}${hint}: "
        read -r _ref
        [[ -z "$_ref" && -n "$default" ]] && _ref="$default"
        [[ -n "$_ref" ]] && return 0
        warn "Value required."
    done
}

prompt_password() {
    local -n _pref=$1
    local msg="$2"
    while true; do
        echo -en "  ${W}${msg}${N}: "
        read -rs _pref; echo ""
        [[ -n "$_pref" ]] && return 0
        warn "Password cannot be empty."
    done
}

SPIN_PID=""
spin_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          echo -en "\r  ${T}${frames[$i]}${N}  ${msg}  "
          i=$(( (i+1) % 10 )); sleep 0.1
      done ) &
    SPIN_PID=$!; disown "$SPIN_PID"
}

spin_stop() {
    if [[ -n "$SPIN_PID" ]]; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null
        SPIN_PID=""; echo -en "\r"
    fi
}

progress_bar() {
    local cur=$1 total=$2 label="${3:-}"
    local width=40
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    local pct=$(( cur * 100 / total ))
    echo -en "\r  ${T}[${bar}]${N} ${W}${pct}%${N}  ${D}${label}${N}  "
}

step() { echo -e "  ${D}[${N}${W}$1${N}${D}/${W}$2${N}${D}]${N}  $3"; }

press_any_key() {
    echo ""
    echo -en "  ${D}Press any key to continue...${N}"
    read -rsn1; echo ""
}
