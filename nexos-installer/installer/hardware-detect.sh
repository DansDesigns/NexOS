#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# hardware-detect.sh — NexOS Hardware Detection
# Detects arch, RAM, CPU, GPU
# ═══════════════════════════════════════════════════════════════

HW_ARCH=""
HW_RAM_MB=0
HW_CPU=""
HW_GPU=""

detect_hardware() {
    # Architecture
    HW_ARCH=$(uname -m)
    case "$HW_ARCH" in
        x86_64)  HW_ARCH="x86_64" ;;
        aarch64) HW_ARCH="aarch64" ;;
        armv7*)  HW_ARCH="armv7" ;;
        *)       warn "Unknown architecture: ${HW_ARCH}" ;;
    esac

    # RAM (in MB)
    HW_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    # CPU model
    HW_CPU=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | \
        sed 's/.*: //' | sed 's/  */ /g' || echo "Unknown")

    # GPU (best-effort)
    if command -v lspci &>/dev/null; then
        HW_GPU=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | \
            head -1 | sed 's/.*: //' || echo "Unknown")
    else
        HW_GPU="Unknown (lspci unavailable)"
    fi

}

show_hardware() {
    section "Hardware"

    echo -e "  ${D}Architecture${N}   ${W}${HW_ARCH}${N}"
    echo -e "  ${D}RAM${N}            ${W}${HW_RAM_MB} MB${N}"
    echo -e "  ${D}CPU${N}            ${W}${HW_CPU}${N}"
    echo -e "  ${D}GPU${N}            ${W}${HW_GPU}${N}"
    echo ""

}

# Compile flags based on arch
get_compile_flags() {
    local flags=""
    case "$HW_ARCH" in
        x86_64)
            flags="-march=native -O2"
            ;;
        aarch64)
            flags="-march=native -O2"
            ;;
        armv7)
            flags="-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2"
            ;;
    esac
    echo "$flags"
}
