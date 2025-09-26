#!/bin/bash
set -euo pipefail

# Enhanced GPU Passthrough Setup Script
# Version: 3.2
# Supports: Arch, Fedora, Ubuntu, Gentoo
# Features: Auto-detection, VFIO config, IOMMU isolation check, ACS override, backups, error handling, logging, AMD 6000 fixes, initramfs regen

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/gpu-passthrough-setup.log"
umask 022

[ "${DEBUG:-false}" == true ] && set -x

trap 'error "Unexpected failure"' ERR

# Logging function with timestamp
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[INFO] $1" | tee -a "$LOG_FILE"
    logger "[INFO] $1"
}

warn() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[WARN] $1" | tee -a "$LOG_FILE"
    logger "[WARN] $1"
}

error() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[ERROR] $1" | tee -a "$LOG_FILE"
    logger "[ERROR] $1"
    exit 1
}

# Configuration defaults
VM=${VM:-""}
GPU=${GPU:-""}
DE=${DE:-auto}
OS=${OS:-auto}
AMD6000=false
USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
INTERACTIVE=${INTERACTIVE:-true}
ACS_OVERRIDE=false
DRY_RUN=${DRY_RUN:-false}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
fi

# CPU detection
CPU=$(lscpu | grep "Vendor ID:" | awk '{print $3}' | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "unknown")
case $CPU in
    genuineintel) IOMMU_PARAM="intel_iommu=on" ;;
    authenticamd) IOMMU_PARAM="amd_iommu=on" ;;
    *) error "Unknown CPU vendor: $CPU"; ;;
esac

log "Detected CPU: $CPU, IOMMU parameter: $IOMMU_PARAM"

# OS detection
detect_os() {
    if [[ "$OS" == "auto" ]]; then
        if command -v pacman >/dev/null 2>&1; then OS=arch
        elif command -v dnf >/dev/null 2>&1; then OS=fedora
        elif command -v apt >/dev/null 2>&1; then OS=ubuntu
        elif command -v emerge >/dev/null 2>&1; then OS=gentoo
        else 
            error "Unable to detect supported OS. Set OS=arch/fedora/ubuntu/gentoo"
        fi
    fi
    if [[ ! "$OS" =~ ^(arch|fedora|ubuntu|gentoo)$ ]]; then
        error "Unsupported OS: $OS"
    fi
    log "OS: $OS"
}

# Package check
check_packages() {
    log "Checking packages..."
    case $OS in
        arch)
            arch_pkgs=("qemu" "libvirt" "edk2-ovmf" "virt-manager" "dnsmasq" "ebtables" "iptables-nft")
            for pkg in "${arch_pkgs[@]}"; do pacman -Q "$pkg" >/dev/null 2>&1 || { echo false; return; }; done
            echo true
            ;;
        fedora)
            fedora_pkgs=("qemu-kvm" "libvirt" "virt-manager" "edk2-ovmf" "swtpm")
            for pkg in "${fedora_pkgs[@]}"; do rpm -q "$pkg" >/dev/null 2>&1 || { echo false; return; }; done
            echo true
            ;;
        ubuntu)
            ubuntu_pkgs=("qemu-kvm" "libvirt-daemon-system" "virt-manager" "ovmf" "bridge-utils" "swtpm-tools")
            for pkg in "${ubuntu_pkgs[@]}"; do dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { echo false; return; }; done
            echo true
            ;;
        gentoo)
            if ! command -v equery >/dev/null 2>&1; then echo false; return; fi
            gentoo_pkgs=("qemu" "libvirt" "virt-manager")
            for pkg in "${gentoo_pkgs[@]}"; do equery list "$pkg" >/dev/null 2>&1 || { echo false; return; }; done
            echo true
            ;;
    esac
}

# Package install
install_packages() {
    log "Installing packages for $OS..."
    case $OS in
        arch)
            pacman -Syu --needed --noconfirm qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables iptables-nft
            ;;
        fedora)
            dnf update -y && dnf group install -y --with-optional virtualization && dnf install -y edk2-ovmf swtpm
            ;;
        ubuntu)
            add-apt-repository universe -y >/dev/null 2>&1 || true
            apt update
            apt install -y qemu-kvm libvirt-daemon-system virt-manager ovmf bridge-utils swtpm-tools
            ;;
        gentoo)
            emerge --ask=n --quiet qemu libvirt virt-manager ebtables dnsmasq swtpm
            ;;
    esac
}

# IOMMU verify
verify_iommu() {
    log "Verifying IOMMU..."
    if ! dmesg | grep -Eiq 'iommu.*enabled|amd.*iommu.*initialized'; then
        warn "IOMMU not enabled. Check BIOS/kernel params."
        return 1
    fi
    if [[ ! -d "/sys/kernel/iommu_groups" ]]; then
        error "No IOMMU groups."
    fi
    local groups=$(find /sys/kernel/iommu_groups -mindepth 1 -maxdepth 1 -type d | wc -l)
    log "IOMMU groups: $groups"
    return 0
}

# Auto-detect GPU
auto_detect_gpu() {
    log "Detecting GPUs..."
    local gpus=() details=()
    # NVIDIA
    if nvidia_info=$(lspci -nn | grep -iE "vga|3d|display.*nvidia"); then
        gpus+=("nvidia")
        details+=("NVIDIA: $nvidia_info")
    fi
    # AMD
    if amd_info=$(lspci -nn | grep -iE "vga|3d|display.*amd|ati"); then
        amd_pci=$(echo "$amd_info" | awk '{print $1}' | sed 's/:$//')
        device_id=$(lspci -nn -s "$amd_pci" | awk -F'[][]' '{print $2}' | cut -d: -f2 | tr '[:lower:]' '[:upper:]')
        audio_pci=$(echo "$amd_pci" | sed 's/\.0$/.1/')
        audio_info=$(lspci -s "$audio_pci" | grep -i audio || echo "")
        audio_text=${audio_info:+" + Audio: $audio_info"}
        if [[ $device_id =~ ^(73[ABCDEF]|74[0-9A-F]|7[56789A-F])[0-9A-F]{2}$ ]]; then
            gpus+=("amd6000")
            details+=("AMD 6000+: $amd_info$audio_text (ID: $device_id)")
        else
            gpus+=("amd")
            details+=("AMD: $amd_info$audio_text (ID: $device_id)")
        fi
    fi
    # Intel
    if intel_info=$(lspci -nn | grep -iE "vga|3d|display.*intel"); then
        gpus+=("intel")
        details+=("Intel: $intel_info")
    fi
    if [[ ${#gpus[@]} -eq 0 ]]; then error "No GPUs detected."; fi
    echo -e "\n${GREEN}GPUs:${NC}"
    for i in "${!details[@]}"; do echo "$((i+1)). ${details[i]}"; done
    if [[ "$INTERACTIVE" == true ]]; then
        if [[ ${#gpus[@]} -eq 1 ]]; then
            read -r -p "Use ${gpus[0]}? (Y/n): " choice
            [[ $choice =~ ^[Nn]$ ]] && manual_gpu_selection || select_gpu "${gpus[0]}"
        else
            for i in "${!gpus[@]}"; do echo "$((i+1)). ${gpus[i]}"; done
            echo "$((${#gpus[@]}+1)). Manual"
            read -r -p "Choice (1-$((${#gpus[@]}+1))): " choice
            if [[ $choice =~ ^[1-9][0-9]*$ ]] && [[ $choice -le ${#gpus[@]} ]]; then
                select_gpu "${gpus[$((choice-1))]}"
            elif [[ $choice -eq $((${#gpus[@]}+1)) ]]; then
                manual_gpu_selection
            else error "Invalid."; fi
        fi
    else select_gpu "${gpus[0]}"; fi
}

select_gpu() {
    local sel=$1
    if [[ "$sel" == "amd6000" ]]; then GPU=amd; AMD6000=true; else GPU=$sel; fi
    log "GPU: $GPU $( [[ $AMD6000 == true ]] && echo "(6000+)" )"
}

manual_gpu_selection() {
    echo "Options: nvidia, amd, amd6000, intel"
    read -r -p "GPU type: " man_gpu
    case $man_gpu in nvidia|intel) GPU=$man_gpu ;; amd) GPU=amd; AMD6000=false ;; amd6000) GPU=amd; AMD6000=true ;; *) error "Invalid."; esac
}

# VM name
auto_detect_vm_name() {
    command -v virsh >/dev/null || error "virsh not found"
    local sug="vm-${GPU}$( [[ $AMD6000 == true ]] && echo "6000" )"
    local exists=$(virsh list --all --name 2>/dev/null | tr '\n' ' ')
    if echo "$exists" | grep -qw "$sug"; then
        local i=1
        while echo "$exists" | grep -qw "${sug}-$i"; do ((i++)); done
        sug="${sug}-$i"
    fi
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "VM name [$sug]: " input
        VM=${input:-$sug}
    else VM=${VM:-$sug}; fi
    if [[ ! $VM =~ ^[a-zA-Z0-9_-]+$ ]]; then error "Invalid VM name."; fi
    if echo "$exists" | grep -qw "$VM"; then
        if [[ "$INTERACTIVE" == true ]]; then
            read -r -p "VM exists. New name? (y/N): " con
            [[ $con =~ ^[Yy]$ ]] && read -r -p "New name: " VM || error "VM $VM exists."
        else
            VM="${VM}-new"
            log "Appended -new to VM name."
        fi
    fi
    log "VM: $VM"
}

# Detect GPU devices
detect_gpu() {
    log "Detecting devices..."
    case $GPU in
        nvidia) GPU_PCI=$(lspci | grep -iE "vga|3d|display.*nvidia" | head -1 | awk '{print $1}' | sed 's/:$//') ;;
        amd) GPU_PCI=$(lspci | grep -iE "amd.*(vga|3d|display)" | head -1 | awk '{print $1}' | sed 's/:$//') ;;
        intel) GPU_PCI=$(lspci | grep -iE "intel.*(vga|3d|display)" | head -1 | awk '{print $1}' | sed 's/:$//') ;;
        *) error "Unsupported GPU."; esac
    [[ -z "$GPU_PCI" ]] && error "No $GPU GPU."
    log "GPU PCI: $GPU_PCI"
    # Simplify audio detection
    AUDIO_PCI=$(lspci | grep -B1 -i audio | grep -E "$(echo $GPU_PCI | cut -d. -f1)\.[01]" | awk '{print $1}' | sed 's/:$//' | head -1 || echo "")
    FULL_GPU="pci_0000_$(echo "$GPU_PCI" | sed 's/:/_/g; s/\./_/g')"
    if [[ -n "$AUDIO_PCI" ]]; then
        FULL_AUDIO="pci_0000_$(echo "$AUDIO_PCI" | sed 's/:/_/g; s/\./_/g')"
        log "Audio PCI: $AUDIO_PCI"
    else
        warn "No audio."
    fi
    local gpu_nn=$(lspci -nn -s $GPU_PCI)
    GPU_ID=$(echo "$gpu_nn" | awk -F'[][]' '{print $2}' | cut -d: -f1 | tr '[:lower:]' '[:upper:]')
    if [[ -n "$AUDIO_PCI" ]]; then
        AUDIO_ID=$(lspci -nn -s $AUDIO_PCI | awk -F'[][]' '{print $2}' | cut -d: -f1 | tr '[:lower:]' '[:upper:]')
    else
        AUDIO_ID=""
    fi
    virsh nodedev-list --tree >/dev/null || warn "virsh nodedev-list failed; check PCI nodes."
    show_iommu_groups
}

show_iommu_groups() {
    log "IOMMU groups:"
    local devs=("$GPU_PCI" ${AUDIO_PCI:+"$AUDIO_PCI"})
    for dev in "${devs[@]}"; do
        local group=$(readlink "/sys/bus/pci/devices/0000:$dev/iommu_group" | sed 's|.*/||')
        [[ -z "$group" ]] && { warn "No group for $dev"; continue; }
        log "Group $group for $dev:"
        local count=0
        while read -r d; do
            lspci -s "$(basename $d)" 2>/dev/null | sed 's/^/  /'
            ((count++))
        done < <(find "/sys/kernel/iommu_groups/$group/devices" -type l)
        if [[ $count -gt ${#devs[@]} ]] && [[ "$INTERACTIVE" == true ]]; then
            read -r -p "Group not isolated ($count devs). Add ACS override? (y/N): " acs
            [[ $acs =~ ^[Yy]$ ]] && ACS_OVERRIDE=true
        elif [[ $count -gt ${#devs[@]} ]]; then
            warn "Group not isolated. Consider ACS override."
        fi
    done
}

# DE detect
detect_de() {
    if [[ "$DE" == auto ]]; then
        DE=$(echo "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]' | sed 's/ .*//')
        case $DE in kde|plasma) DE=plasma ;; gnome) DE=gnome ;; xfce) DE=xfce ;; *) DE=other ;; esac
        [[ -z "$DE" ]] && { pgrep -x plasma-session >/dev/null && DE=plasma || pgrep -x gnome-shell >/dev/null && DE=gnome || DE=other; }
    fi
    log "DE: $DE"
}

# Kernel params append if not present
append_kernel_params() {
    local params="$IOMMU_PARAM iommu=pt"
    [[ "$GPU" == nvidia ]] && params="$params rd.driver.blacklist=nouveau modprobe.blacklist=nouveau"
    [[ "$GPU" == intel ]] && params="$params rd.driver.blacklist=i915 modprobe.blacklist=i915"
    [[ "$ACS_OVERRIDE" == true ]] && params="$params pcie_acs_override=downstream,multifunction"
    if [[ "$INTERACTIVE" == true ]]; then
        echo "Params: $params"
        read -r -p "Add? (y/N): " ans
        [[ $ans =~ ^[Yy]$ ]] || return 0
    fi
    log "Updating kernel params..."
    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "$params" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak.$(date +%s)
            sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/\" $params\"/" /etc/default/grub
            if command -v grub-mkconfig >/dev/null; then grub-mkconfig -o /boot/grub/grub.cfg
            elif command -v grub2-mkconfig >/dev/null; then grub2-mkconfig -o /boot/grub2/grub2.cfg; fi
        else
            log "Params already present."
        fi
    fi
    if [[ -d /boot/loader/entries ]]; then
        for f in /boot/loader/entries/*.conf; do
            [[ -f "$f" ]] || continue
            if ! grep -q "$params" "$f"; then
                cp "$f" "${f}.bak.$(date +%s)"
                sed -i "/^options / s/$/ $params/" "$f"
            fi
        done
    fi
    regen_initramfs
    warn "Reboot required."
}

regen_initramfs() {
    case $OS in
        arch) mkinitcpio -P || error "Failed initramfs" ;;
        fedora) dracut --regenerate-all -f || error "Failed initramfs" ;;
        ubuntu) update-initramfs -u -k all || error "Failed initramfs" ;;
        gentoo) genkernel --no-cleanup initramfs || error "Failed initramfs" ;;
    esac
    log "Initramfs regenerated."
}

# VFIO setup
setup_vfio() {
    log "Setting VFIO..."
    local vfio="/etc/modprobe.d/vfio.conf"
    grep -q "$GPU_ID" "$vfio" 2>/dev/null && log "VFIO already configured." && return 0
    [[ -f "$vfio" ]] && cp "$vfio" "${vfio}.bak.$(date +%s)"
    echo "options vfio-pci ids=$GPU_ID$( [[ -n "$AUDIO_ID" ]] && echo ",$AUDIO_ID" )" > "$vfio"
    if [[ "$GPU" == nvidia ]]; then
        local black="/etc/modprobe.d/blacklist-nouveau.conf"
        grep -q "blacklist nouveau" "$black" 2>/dev/null && return 0
        [[ -f "$black" ]] && cp "$black" "${black}.bak.$(date +%s)"
        cat > "$black" << EOF
blacklist nouveau
options nouveau modeset=0
EOF
    fi
    if [[ "$GPU" == intel ]]; then
        local black="/etc/modprobe.d/blacklist-i915.conf"
        grep -q "blacklist i915" "$black" 2>/dev/null && return 0
        [[ -f "$black" ]] && cp "$black" "${black}.bak.$(date +%s)"
        cat > "$black" << EOF
blacklist i915
options i915 enable_psr=0
EOF
    fi
    regen_initramfs
}

# Libvirt setup
setup_libvirt() {
    log "Libvirt setup..."
    for g in libvirt kvm input; do getent group "$g" >/dev/null && usermod -aG "$g" "$USER" || warn "Group $g missing."; done
    systemctl enable --now libvirtd 2>/dev/null || { systemctl enable --now libvirtd.service || true; }
    virsh net-start default >/dev/null 2>&1 && virsh net-autostart default >/dev/null 2>&1 || log "Default net ok."
    setup_qemu_conf
}

setup_qemu_conf() {
    local conf="/etc/libvirt/qemu.conf"
    [[ -f "$conf" ]] && cp "$conf" "${conf}.bak.$(date +%s)"
    grep -q "user = \"$USER\"" "$conf" || sed -i "s/^#\s*user =.*/user = \"$USER\"/" "$conf" || echo "user = \"$USER\"" >> "$conf"
    grep -q "group = \"kvm\"" "$conf" || sed -i "s/^#\s*group =.*/group = \"kvm\"/" "$conf" || echo "group = \"kvm\"" >> "$conf"
    if ! grep -q cgroup_device_acl "$conf"; then
        cat >> "$conf" << EOF

cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/rtc",
    "/dev/hpet", "/dev/sev"
]
EOF
    fi
}

# Hooks
create_libvirt_hooks() {
    log "Creating hooks for $VM"
    local hooks="/etc/libvirt/hooks"
    [[ -d "$hooks" ]] && { [[ "$INTERACTIVE" == true ]] && read -r -p "Backup/remove existing? (y/N): " clean; [[ $clean =~ ^[Yy]$ ]] && { mkdir "/root/hooks.bak.$(date +%s)"; cp -r "$hooks" "/root/hooks.bak.$(date +%s)/"; rm -rf "$hooks"; }; } || mkdir -p "$hooks"
    mkdir -p "$hooks/qemu.d/$VM/prepare/begin" "$hooks/qemu.d/$VM/release/end"
    cat > "$hooks/qemu" << 'EOF'
#!/bin/bash
GUEST_NAME="$1" HOOK_NAME="$2" STATE_NAME="$3" MISC="${@:4}"
BASEDIR="$(dirname $0)" HOOKPATH="$BASEDIR/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"
set -e
logger "libvirt-hook: $GUEST_NAME $HOOK_NAME $STATE_NAME"
if [ -f "$HOOKPATH" ]; then
  "$HOOKPATH" "$@"
elif [ -d "$HOOKPATH" ]; then
  find -L "$HOOKPATH" -maxdepth 1 -type f -executable -print0 | sort -z | xargs -0 -I {} "{}" "$@"
fi
EOF
    chmod +x "$hooks/qemu"
    create_start_hook "$hooks/qemu.d/$VM/prepare/begin/start.sh"
    create_stop_hook "$hooks/qemu.d/$VM/release/end/stop.sh"
}

create_start_hook() {
    local p="$1"
    cat > "$p" << EOF
#!/bin/bash
set -x
logger "Start GPU passthrough for $VM"
USER=\$(logname 2>/dev/null || echo $USER)
systemctl stop display-manager.service || true
EOF
    if [[ "$DE" == plasma ]]; then cat >> "$p" << EOF
[[ -n "\$USER" ]] && systemctl --user -M "\$USER@" stop plasma* || true
EOF
    fi
    cat >> "$p" << EOF
pkill -TERM -u "\$USER" Xorg || true
pkill -TERM -u "\$USER" -f wayland || true
sleep 2
echo 0 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
EOF
    if [[ "$AMD6000" != true ]]; then cat >> "$p" << EOF
echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind || true
EOF
    fi
    if [[ "$GPU" == nvidia ]]; then cat >> "$p" << EOF
modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia || true
EOF
    elif [[ "$GPU" == amd ]]; then cat >> "$p" << EOF
modprobe -r amdgpu || true
EOF
    elif [[ "$GPU" == intel ]]; then cat >> "$p" << EOF
modprobe -r i915 || true
EOF
    fi
    cat >> "$p" << EOF
virsh nodedev-detach $FULL_GPU || true
EOF
    [[ -n "$FULL_AUDIO" ]] && cat >> "$p" << EOF
virsh nodedev-detach $FULL_AUDIO || true
EOF
    cat >> "$p" << EOF
modprobe vfio-pci || true
EOF
    chmod +x "$p"
}

create_stop_hook() {
    local p="$1"
    cat > "$p" << EOF
#!/bin/bash
set -x
virsh nodedev-reattach $FULL_GPU || true
EOF
    [[ -n "$FULL_AUDIO" ]] && cat >> "$p" << EOF
virsh nodedev-reattach $FULL_AUDIO || true
EOF
    cat >> "$p" << EOF
modprobe -r vfio-pci || true
EOF
    if [[ "$GPU" == amd ]]; then cat >> "$p" << EOF
modprobe amdgpu || true
EOF
    elif [[ "$GPU" == intel ]]; then cat >> "$p" << EOF
modprobe i915 || true
EOF
    fi
    if [[ "$AMD6000" != true ]]; then cat >> "$p" << EOF
echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind || true
EOF
    fi
    if [[ "$GPU" == nvidia ]]; then cat >> "$p" << EOF
nvidia-xconfig --query-gpu-info > /dev/null 2>&1 || true
modprobe nvidia_drm || true
modprobe nvidia_modeset || true
modprobe nvidia_uvm || true
modprobe nvidia || true
EOF
    fi
    cat >> "$p" << EOF
echo 1 > /sys/class/vtconsole/vtcon0/bind 2>/dev/null || true
echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null || true
systemctl start display-manager || true
EOF
    chmod +x "$p"
}

# Main
main() {
    if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; log "Dry-run mode."; return 0; fi
    detect_os
    if [[ "$(check_packages)" != true ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            read -r -p "Install? (y/N): " inst
            [[ $inst =~ ^[Yy]$ ]] && install_packages || { warn "Skipping install."; return 1; }
        else
            install_packages
        fi
    fi
    verify_iommu || warn "IOMMU issues."
    auto_detect_gpu
    detect_de
    auto_detect_vm_name
    detect_gpu
    setup_vfio
    append_kernel_params
    setup_libvirt
    create_libvirt_hooks
    echo -e "\n${GREEN}Complete!${NC} Reboot. Add to VM: $FULL_GPU $( [[ -n "$FULL_AUDIO" ]] && echo "$FULL_AUDIO" )."
    if [[ "$INTERACTIVE" == true ]]; then
        read -r -p "Dump vBIOS? (y/N): " vb
        if [[ $vb =~ ^[Yy]$ ]]; then
            local vbios="/root/$VM-vbios.rom"
            if [[ -f "$vbios" ]]; then
                read -r -p "vBIOS exists. Overwrite? (y/N): " ow
                [[ $ow =~ ^[Nn]$ ]] && return 0
            fi
            echo 1 > /sys/bus/pci/devices/0000:$GPU_PCI/rom
            cat /sys/bus/pci/devices/0000:$GPU_PCI/rom > "$vbios"
            echo 0 > /sys/bus/pci/devices/0000:$GPU_PCI/rom
            log "vBIOS: $vbios"
        fi
    fi
}

main "$@"
