# VFIO Single GPU Passthrough Guide (Updated Sep 2025)

**Note**: Limited support. Ask at [r/VFIO](https://reddit.com/r/vfio).

## Table Of Contents
* **[IOMMU Setup](#enable--verify-iommu)**
* **[Resizable BAR](#resizable-bar)**
* **[Installing Packages](#install-required-tools)**
* **[Enabling Services](#enable-required-services)**
* **[Guest Setup](#setup-guest-os)**
* **[Attaching PCI Devices](#attaching-pci-devices)**
* **[Libvirt Hooks](#libvirt-hooks)**
* **[Automation Script](#automation-script)**
* **[Keyboard/Mouse Passthrough](#keyboardmouse-passthrough)**
* **[Video Card Virtualisation Detection](#video-card-driver-virtualisation-detection)**
* **[Audio Passthrough](#audio-passthrough)**
* **[GPU Reset for AMD](#gpu-reset-for-amd)**
* **[GPU vBIOS Patching](#vbios-patching)**

### Enable & Verify IOMMU
**BIOS Settings**  
Enable **Intel VT-d** or **AMD-Vi**. Disable **Resizable BAR** if issues (see [below](#resizable-bar)).

**Kernel Parameter** (detect CPU: Intel/AMD via `/proc/cpuinfo`).

<details>
<summary><b>GRUB</b></summary>

Edit `/etc/default/grub`:  
`GRUB_CMDLINE_LINUX_DEFAULT="... intel_iommu=on iommu=pt ..."` or `amd_iommu=on`.  

```sh
grub-mkconfig -o /boot/grub/grub.cfg
```
</details>

<details>
<summary><b>Systemd Boot</b></summary>

Edit `/boot/loader/entries/*.conf`:  
`options root=UUID=... intel_iommu=on iommu=pt` or `amd_iommu=on`.
</details>

Reboot. Verify:  
```sh
dmesg | grep IOMMU
```
Expected: `Intel-IOMMU: enabled` or `AMD-Vi: AMD IOMMUv2 loaded`.

IOMMU groups script:  
```sh
#!/bin/bash
shopt -s nullglob
for g in `find /sys/kernel/iommu_groups/* -maxdepth 0 -type d | sort -V`; do
    echo "IOMMU Group ${g##*/}:"
    for d in $g/devices/*; do
        echo -e "\t$(lspci -nns ${d##*/})"
    done;
done;
```
Pass all in GPU group. Use [ACS override](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Bypassing_the_IOMMU_groups_(ACS_override_patch)) to isolate.

### Resizable BAR
Kernel 6.1+ supports ReBAR. Enable in BIOS for perf gain. For AMD, avoid Code 43 with udev rule:  
`/etc/udev/rules.d/01-amd.rules`  
```
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource0_resize}="14"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource2_resize}="8"
```
Reload: `udevadm control --reload`. Set BAR2=8MB (value 3) if needed.

### Install required tools
Add vendor-reset for AMD reset bug.

<details>
<summary><b>Gentoo Linux</b></summary>

```sh
emerge -av qemu virt-manager libvirt ebtables dnsmasq vendor-reset
```
</details>

<details>
<summary><b>Arch Linux</b></summary>

```sh
pacman -S qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables vendor-reset
```
</details>

<details>
<summary><b>Fedora</b></summary>

```sh
dnf install @virtualization vendor-reset
```
</details>

<details>
<summary><b>Ubuntu</b></summary>

```sh
apt install qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf vendor-reset
```
</details>

### Enable required services
<details>
<summary><b>SystemD</b></summary>

```sh
systemctl enable --now libvirtd
modprobe vendor-reset  # For AMD
```
</details>

<details>
<summary><b>OpenRC</b></summary>

```sh
rc-update add libvirtd default
rc-service libvirtd start
```
</details>

Start default net:  
```sh
virsh net-start default
virsh net-autostart default
```

### Setup Guest OS
Add user to groups:  
```sh
usermod -aG kvm,input,libvirt $USER
```
Download [virtio](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).  
In virt-manager: Q35 chipset, UEFI firmware, host-passthrough CPU, virtio disk/NIC. Load virtio drivers during install. Remove ISO post-install.

### Attaching PCI devices
Remove Spice/QXL/ich*. Add PCI Host for GPU VGA/HDMI Audio.

### Libvirt Hooks
Automate via hooks. For AMD 6000: Skip EFI framebuffer unbind/rebind; unload amdgpu after detach. For Plasma Wayland: Stop user services.

See [PassthroughPost](https://passthroughpo.st/simple-per-vm-libvirt-hooks-with-the-vfio-tools-hook-helper/).

<details>
<summary><b>Create Hook</b></summary>

```sh
mkdir /etc/libvirt/hooks
touch /etc/libvirt/hooks/qemu
chmod +x /etc/libvirt/hooks/qemu
```

`/etc/libvirt/hooks/qemu`:  
```sh
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
</details>

### Automation Script
`vfio-setup.sh` automates for OS/GPU/DE/VM. Detects CPU/bootloader/PCI. Run as root: `./vfio-setup.sh --vm=win10 --gpu=nvidia --de=plasma --os=arch --amd6000=false`

```sh
#!/bin/bash
set -e

# Defaults
VM=${VM:-win10}
GPU=${GPU:-nvidia}
DE=${DE:-other}
OS=${OS:-auto}
AMD6000=false
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

# Install packages
case $OS in
  arch) pacman -S --noconfirm qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables vendor-reset ;;
  fedora) dnf install -y @virtualization vendor-reset ;;
  ubuntu) apt update && apt install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients bridge-utils virt-manager ovmf vendor-reset ;;
  gentoo) emerge -av qemu virt-manager libvirt ebtables dnsmasq vendor-reset ;;
esac
systemctl enable --now libvirtd
modprobe vendor-reset

# Kernel params
if [ -f /etc/default/grub ]; then
  sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"${IOMMU_PARAM} iommu=pt\"/" /etc/default/grub
  grub-mkconfig -o /boot/grub/grub.cfg
elif [ -d /boot/loader/entries ]; then
  for conf in /boot/loader/entries/*.conf; do
    sed -i "s/options root=.*/options root=... ${IOMMU_PARAM} iommu=pt/" "$conf"
  done
fi

# Detect GPU PCI (VGA + Audio)
GPU_PCI=$(lspci | grep -i vga | grep -i $GPU | head -1 | awk '{print $1}' | sed 's/://')
AUDIO_PCI=$(lspci | grep -i audio | grep -A1 "$GPU_PCI" | tail -1 | awk '{print $1}' | sed 's/://')
FULL_GPU="pci_0000_${GPU_PCI//:/_}"
FULL_AUDIO="pci_0000_${AUDIO_PCI//:/_}"

# If AMD6000, check device ID (e.g., 73bf for 6700XT)
if [ "$GPU" = "amd" ] && lspci -nn | grep "$GPU_PCI" | grep -q "10de\|1002.*\(73a[0-9]\|73b[0-9]\|73c[0-9]\|73d[0-9]\|73e[0-9]\|73f[0-9]\)"; then AMD6000=true; fi

# Hooks dir
HOOKS_DIR="/etc/libvirt/hooks/qemu.d/${VM}/prepare/begin"
mkdir -p "$HOOKS_DIR" "/etc/libvirt/hooks/qemu.d/${VM}/release/end"

# Start hook
cat > "$HOOKS_DIR/start.sh" << EOF
#!/bin/bash
set -x
systemctl stop display-manager
if [ "$DE" = "plasma" ]; then
  systemctl --user -M \$USER stop plasma*  # Wayland
fi
echo 0 > /sys/class/vtconsole/vtcon0/bind
echo 0 > /sys/class/vtconsole/vtcon1/bind
$( [ "$AMD6000" = false ] && echo 'echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind' || echo '#' )
$( [ "$GPU" = "nvidia" ] && echo 'modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia' )
$( [ "$GPU" = "amd" ] && echo '# modprobe -r amdgpu  # After detach' )
virsh nodedev-detach $FULL_GPU
virsh nodedev-detach $FULL_AUDIO
$( [ "$GPU" = "amd" ] && echo 'modprobe -r amdgpu' )
modprobe vfio-pci
EOF
chmod +x "$HOOKS_DIR/start.sh"

# Stop hook
cat > "/etc/libvirt/hooks/qemu.d/${VM}/release/end/stop.sh" << EOF
#!/bin/bash
set -x
virsh nodedev-reattach $FULL_GPU
virsh nodedev-reattach $FULL_AUDIO
modprobe -r vfio-pci
$( [ "$GPU" = "amd" ] && echo 'modprobe amdgpu' )
$( [ "$GPU" = "nvidia" ] && echo 'modprobe nvidia_drm nvidia_modeset nvidia_uvm nvidia' )
$( [ "$AMD6000" = false ] && echo 'echo "efi-framebuffer.0" > /sys/bus/platform/drivers/efi-framebuffer/bind' || echo '#' )
echo 1 > /sys/class/vtconsole/vtcon0/bind
echo 1 > /sys/class/vtconsole/vtcon1/bind
systemctl start display-manager
if [ "$DE" = "plasma" ]; then
  systemctl --user -M \$USER start plasma*
fi
EOF
chmod +x "/etc/libvirt/hooks/qemu.d/${VM}/release/end/stop.sh"

echo "Setup complete. Reboot. Edit VM in virt-manager."
```

### Keyboard/Mouse Passthrough
USB Host or Evdev. For Evdev: Edit VM XML, add qemu:commandline for /dev/input/by-id/*event-kbd/mouse. Update /etc/libvirt/qemu.conf cgroup_acl. Use virtio input.

### Video Card Driver Virtualisation Detection
Spoof Hyper-V: `<vendor_id state='on' value='whatever'/>`. Hide KVM for NVIDIA: `<kvm><hidden state='on'/></kvm>`.

### Audio Passthrough
PipeWire/JACK or PulseAudio. See original for XML.

### GPU Reset for AMD
Load `vendor-reset` module for RX 6000 reset bug (Code 43).

### vBIOS Patching
Dump: `echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/rom; sudo cat ... > vbios.rom; echo 0 | sudo tee ...`  
Trim header in hex editor (remove before 0x55 after "VIDEO"). Add to hostdev: `<rom file='/path/patched.rom'/>`.

### See Also
[Single GPU Passthrough Troubleshooting](https://docs.google.com/document/d/17Wh9_5HPqAx8HHk-p2bGlR0E-65TplkG18jvM98I7V8)<br/>
[joeknock90](https://github.com/joeknock90/Single-GPU-Passthrough)<br/>
[YuriAlek](https://gitlab.com/YuriAlek/vfio)<br/>
[wabulu](https://github.com/wabulu/Single-GPU-passthrough-amd-nvidia)<br/>
[ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)<br/>
[Gentoo](https://wiki.gentoo.org/wiki/GPU_passthrough_with_libvirt_qemu_kvm)<br/>
[Muxless 2025](https://github.com/ArshamEbr/Muxless-GPU-Passthrough)
