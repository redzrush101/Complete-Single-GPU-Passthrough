# VFIO Single GPU Passthrough Guide (Updated Sep 2025)

**Note**: Limited support. Ask at [r/VFIO](https://reddit.com/r/vfio). Guides like [Muxless 2025](https://github.com/ArshamEbr/Muxless-GPU-Passthrough) cover laptop muxless setups.

## Table of Contents
* **[IOMMU Setup](#iommu-setup)**
* **[Resizable BAR](#resizable-bar)**
* **[Install Packages](#install-packages)**
* **[Enable Services](#enable-services)**
* **[Guest Setup](#guest-setup)**
* **[Attach PCI Devices](#attach-pci-devices)**
* **[Libvirt Hooks](#libvirt-hooks)**
* **[Automation Script](#automation-script)**
* **[Keyboard/Mouse Passthrough](#keyboardmouse-passthrough)**
* **[VM Detection Spoofing](#vm-detection-spoofing)**
* **[Audio Passthrough](#audio-passthrough)**
* **[AMD GPU Reset](#amd-gpu-reset)**
* **[vBIOS Patching](#vbios-patching)**

## IOMMU Setup

### BIOS Settings
- Enable **Intel VT-d** or **AMD-Vi**.
- Disable **Resizable BAR** if black screens occur (see [below](#resizable-bar)).

### Kernel Parameters
Auto-detect CPU vendor from `/proc/cpuinfo` for `intel_iommu=on` or `amd_iommu=on iommu=pt`.

| Bootloader | Config File | Command |
|------------|-------------|---------|
| **GRUB** | `/etc/default/grub` | `GRUB_CMDLINE_LINUX_DEFAULT="... intel_iommu=on iommu=pt ..."` <br> `grub-mkconfig -o /boot/grub/grub.cfg` |
| **systemd-boot** | `/boot/loader/entries/*.conf` | `options root=UUID=... intel_iommu=on iommu=pt` |

Reboot. Verify:  
```bash
dmesg | grep IOMMU
```
Expected: `Intel-IOMMU: enabled` or `AMD-Vi: AMD IOMMUv2 loaded`.

### IOMMU Groups
Script to list:  
```bash
#!/bin/bash
shopt -s nullglob
for g in $(find /sys/kernel/iommu_groups/* -maxdepth 0 -type d | sort -V); do
    echo "IOMMU Group ${g##*/}:"
    for d in $g/devices/*; do
        echo -e "\t$(lspci -nns ${d##*/})"
    done
done
```
Pass all devices in GPU's group. Isolate with [ACS override patch](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Bypassing_the_IOMMU_groups_(ACS_override_patch)).

## Resizable BAR
Kernel 6.1+ supports ReBAR for perf gains. Enable in BIOS. For AMD RX 6000 (e.g., 6700XT, device 0x73bf), avoid Code 43 with udev rule:  

`/etc/udev/rules.d/01-amd.rules`  
```bash
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource0_resize}="14"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource2_resize}="8"
```
Reload: `udevadm control --reload`. Set BAR2=8MB (value 3) if needed.

## Install Packages
Core virtualization tools only. For AMD reset, see [below](#amd-gpu-reset).

| Distro | Command |
|--------|---------|
| **Gentoo** | `emerge -av qemu virt-manager libvirt ebtables dnsmasq` |
| **Arch** | `pacman -S qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables` |
| **Fedora** | `dnf install @virtualization` |
| **Ubuntu** | `apt update && apt install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf` |

## Enable Services
**SystemD**:  
```bash
systemctl enable --now libvirtd
```

Start default network:  
```bash
virsh net-start default
virsh net-autostart default
```

**Note**: For OpenRC or other inits, manually enable/start libvirtd.

## Guest Setup
Add user to groups:  
```bash
usermod -aG kvm,input,libvirt $USER
```
Download [virtio ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).  

In virt-manager:  
- Chipset: **Q35**, Firmware: **UEFI**.  
- CPU: **host-passthrough**, topology to match host.  
- Disk/NIC: **virtio**. Load drivers from ISO during Windows install (select `amd64/win10`).  
- Remove ISO after.  

**2025 Note**: Anti-cheat (e.g., Valorant) often works at ~99% native perf.

## Attach PCI Devices
Remove Spice/QXL/ich* devices. Add **PCI Host Device** for GPU VGA + HDMI Audio.

## Libvirt Hooks
Automate unbind/rebind. Skip EFI framebuffer for AMD 6000 series; unload `amdgpu` after detach. For KDE Plasma Wayland: Stop user services.  

See [PassthroughPost](https://passthroughpo.st/simple-per-vm-libvirt-hooks-with-the-vfio-tools-hook-helper/).

### Create Main Hook
```bash
mkdir /etc/libvirt/hooks
touch /etc/libvirt/hooks/qemu
chmod +x /etc/libvirt/hooks/qemu
```

`/etc/libvirt/hooks/qemu`:  
```bash
#!/bin/bash
GUEST_NAME="$1" HOOK_NAME="$2" STATE_NAME="$3" MISC="${@:4}"
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
```

### Start/Stop Scripts
See [Automation Script](#automation-script) for full examples (per VM: `win10/prepare/begin/start.sh` & `release/end/stop.sh`).

## Automation Script
`vfio-setup.sh` automates detection/install for OS/GPU/DE/VM. Checks packages, prompts for IOMMU. Run as root: `./vfio-setup.sh --vm=win10 --gpu=nvidia --de=plasma`.

```bash
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
    fedora) dnf install -y @virtualization ;;
    ubuntu) apt update && apt install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf ;;
    gentoo) emerge -q qemu virt-manager libvirt ebtables dnsmasq ;;
  esac
else
  echo "Packages already installed."
fi

usermod -aG libvirt,kvm,input "$USER"
systemctl enable --now libvirtd

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

echo "Setup complete. Reboot. Edit VM in virt-manager."
```

## Keyboard/Mouse Passthrough
Use USB Host Device or Evdev passthrough. For Evdev:  
- Edit VM XML: Add `qemu:commandline` for `/dev/input/by-id/*event-kbd` & `*event-mouse`.  
- Update `/etc/libvirt/qemu.conf` `cgroup_device_acl`.  
- Switch to virtio input devices.

## VM Detection Spoofing
For drivers refusing VM:  
- Hyper-V spoof: `<hyperv><vendor_id state='on' value='whatever'/></hyperv>`.  
- NVIDIA: Hide KVM `<kvm><hidden state='on'/></kvm>`.

## Audio Passthrough
Route via PipeWire/JACK or PulseAudio. Example XML in [ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Passing_audio_from_virtual_machine_to_host_via_JACK_and_PipeWire). Use [Scream](https://wiki.archlinux.org/index.php/PCI_passthrough_via_OVMF#Passing_VM_audio_to_host_via_Scream) alternative.

## AMD GPU Reset
For RX 6000 series reset (Code 43), manually install `vendor-reset` module from [GitHub](https://github.com/gnif/vendor-reset):  
- Arch: AUR `vendor-reset-dkms-git`.  
- Fedora: COPR `kylegospo/vendor-reset-dkms`.  
- Ubuntu: Build DKMS manually.  
- Gentoo: `emerge app-emulation/vendor-reset`.  
Load via `modprobe vendor-reset` in hooks if needed. Check kernel compatibility.

## vBIOS Patching
Dump ROM:  
```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
sudo cat /sys/bus/pci/devices/0000:01:00.0/rom > vbios.rom
echo 0 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom
```
Trim in hex editor (NVIDIA: remove before 0x55 after "VIDEO"). Add to hostdev: `<rom file='/path/patched.rom'/>`.

## See Also
- [Troubleshooting](https://docs.google.com/document/d/17Wh9_5HPqAx8HHk-p2bGlR0E-65TplkG18jvM98I7V8)  
- [joeknock90](https://github.com/joeknock90/Single-GPU-Passthrough)  
- [YuriAlek](https://gitlab.com/YuriAlek/vfio)  
- [wabulu](https://github.com/wabulu/Single-GPU-passthrough-amd-nvidia)  
- [ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)  
- [Gentoo Wiki](https://wiki.gentoo.org/wiki/GPU_passthrough_with_libvirt_qemu_kvm)  
- [Muxless 2025](https://github.com/ArshamEbr/Muxless-GPU-Passthrough)
