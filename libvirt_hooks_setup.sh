#!/bin/bash
set -e

# Defaults
VM=${VM:-win10}
GPU=${GPU:-nvidia}
DE=${DE:-other}
OS=${OS:-auto}
AMD6000=false
USER=${SUDO_USER:-$(logname 2>/dev/null || whoami)}
CPU=$(grep -i 'vendor_id' /proc/cpuinfo | head -1 | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
IOMMU_PARAM=$([ $CPU = "genuineintel" ] && echo "intel_iommu=on" || echo "amd_iommu=on")

# Detect OS
if [ "$OS" = "auto" ]; then
  if command -v pacman >/dev/null; then OS=arch
  elif command -v dnf >/dev/null; then OS=fedora
  elif command -v apt >/dev/null; then OS=ubuntu
  elif command -v emerge >/dev/null; then OS=gentoo
  else echo "Unknown OS"; exit 1; fi
fi

# Check if packages installed
PACKAGES_INSTALLED=true
case $OS in
  arch) [[ $(pacman -Q qemu libvirt virt-manager 2>/dev/null | wc -l) -ge 3 ]] || PACKAGES_INSTALLED=false ;;
  fedora) [[ $(rpm -q qemu-kvm libvirt virt-manager 2>/dev/null | wc -l) -ge 3 ]] || PACKAGES_INSTALLED=false ;;
  ubuntu) [[ $(dpkg -l | grep -c '^ii  qemu-kvm libvirt-clients virt-manager' 2>/dev/null) -ge 3 ]] || PACKAGES_INSTALLED=false ;;
  gentoo) command -v equery >/dev/null && [[ $(equery list qemu libvirt virt-manager 2>/dev/null | wc -l) -ge 3 ]] || PACKAGES_INSTALLED=false ;;
esac

if [ "$PACKAGES_INSTALLED" = false ]; then
  case $OS in
    arch) pacman -S --noconfirm qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables ;;
    fedora) dnf install -y @virtualization ; dnf copr enable kylegospo/vendor-reset-dkms -y ; dnf install -y vendor-reset-dkms ;;
    ubuntu) apt update && apt install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf ;;
    gentoo) emerge -q qemu virt-manager libvirt ebtables dnsmasq vendor-reset ;;
  esac
else
  echo "Packages already installed."
fi

usermod -aG libvirt,kvm,input "$USER"
systemctl enable --now libvirtd
modprobe vendor-reset || true

# Kernel params prompt
echo "Add IOMMU params to bootloader? (y/n)"
read -r ans
if [[ $ans =~ ^[Yy] ]]; then
  if [ -f /etc/default/grub ]; then
    if ! grep -q "$IOMMU_PARAM" /etc/default/grub; then
      sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_PARAM iommu=pt\"/" /etc/default/grub
      grub-mkconfig -o /boot/grub/grub.cfg
    fi
  elif [ -d /boot/loader/entries ]; then
    for conf in /boot/loader/entries/*.conf; do
      if ! grep -q "iommu=" "$conf"; then
        sed -i "/^options / s/\$/ $IOMMU_PARAM iommu=pt/" "$conf"
      fi
    done
  fi
fi

# Detect GPU PCI (VGA + Audio)
GPU_PCI=$(lspci | grep -i vga | grep -i "$GPU" | head -1 | awk '{print $1}' | sed 's/://')
AUDIO_PCI=$(lspci | grep -A1 -i " ${GPU_PCI}:" | grep -i audio | head -1 | awk '{print $1}' | sed 's/://' || echo "${GPU_PCI/%.0/.1}")
FULL_GPU="pci_0000_$(echo "$GPU_PCI" | sed 's/:/_/g;s/\./_/g')"
[ -n "$AUDIO_PCI" ] && FULL_AUDIO="pci_0000_$(echo "$AUDIO_PCI" | sed 's/:/_/g;s/\./_/g')" || FULL_AUDIO=""

# If AMD6000, check device ID
if [ "$GPU" = "amd" ] && lspci -nn | grep "$GPU_PCI" | grep -q "1002:73[abcdef][0-9a-f][0-9a-f]"; then AMD6000=true; fi

# Libvirt hooks setup
mkdir -p /etc/libvirt/hooks
cat > /etc/libvirt/hooks/qemu << 'EOF'
#!/bin/bash

GUEST_NAME="$1"
HOOK_NAME="$2"
STATE_NAME="$3"
MISC="${@:4}"

BASEDIR="$(dirname $0)"

HOOKPATH="$BASEDIR/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"
set -e

if [ -f "$HOOKPATH" ]; then
  eval "\"$HOOKPATH\"" "$@"
elif [ -d "$HOOKPATH" ]; then
  while read file; do
    eval "\"$file\"" "$@"
  done <<< "$(find -L "$HOOKPATH" -maxdepth 1 -type f -executable -print;)"
fi
EOF
chmod +x /etc/libvirt/hooks/qemu

HOOKS_DIR="/etc/libvirt/hooks/qemu.d/${VM}/prepare/begin"
mkdir -p "$HOOKS_DIR" "/etc/libvirt/hooks/qemu.d/${VM}/release/end"

# Start hook
cat > "$HOOKS_DIR/start.sh" << EOF
#!/bin/bash
set -x
USER=\$(logname 2>/dev/null || whoami)
systemctl stop display-manager
$( [ "$DE" = "plasma" ] && echo 'if [ -n "\$USER" ]; then systemctl --user -M \$USER stop plasma* ; fi' || echo '#' )
echo 0 > /sys/class/vtconsole/vtcon0/bind
echo 0 > /sys/class/vtconsole/vtcon1/bind
$( [ "$AMD6000" = false ] && echo 'echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind' || echo '#' )
$( [ "$GPU" = "nvidia" ] && echo 'modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia' )
virsh nodedev-detach $FULL_GPU
[ -n "$FULL_AUDIO" ] && virsh nodedev-detach $FULL_AUDIO
$( [ "$GPU" = "amd" ] && echo 'modprobe -r amdgpu' )
modprobe vfio-pci
EOF
chmod +x "$HOOKS_DIR/start.sh"

# Stop hook
cat > "/etc/libvirt/hooks/qemu.d/${VM}/release/end/stop.sh" << EOF
#!/bin/bash
set -x
USER=\$(logname 2>/dev/null || whoami)
virsh nodedev-reattach $FULL_GPU
[ -n "$FULL_AUDIO" ] && virsh nodedev-reattach $FULL_AUDIO
modprobe -r vfio-pci
$( [ "$GPU" = "amd" ] && echo 'modprobe amdgpu' )
$( [ "$GPU" = "nvidia" ] && echo 'modprobe nvidia' )
$( [ "$AMD6000" = false ] && echo 'echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind' || echo '#' )
echo 1 > /sys/class/vtconsole/vtcon0/bind
echo 1 > /sys/class/vtconsole/vtcon1/bind
systemctl start display-manager
$( [ "$DE" = "plasma" ] && echo 'if [ -n "\$USER" ]; then systemctl --user -M \$USER start plasma* ; fi' || echo '#' )
EOF
chmod +x "/etc/libvirt/hooks/qemu.d/${VM}/release/end/stop.sh"

echo "Setup complete. Reboot. Edit VM in virt-manager. Install vendor-reset manually for Arch/Ubuntu if needed."
