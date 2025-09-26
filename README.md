# VFIO Single GPU Passthrough Guide (Sep 2025)

**Note**: Limited support. Ask at [r/VFIO](https://reddit.com/r/vfio). For laptops, see [Muxless 2025](https://github.com/ArshamEbr/Muxless-GPU-Passthrough).

## Table of Contents
- [IOMMU Setup](#iommu-setup)
- [Resizable BAR](#resizable-bar)
- [Packages](#packages)
- [Services](#services)
- [Guest VM](#guest-vm)
- [PCI Attachment](#pci-attachment)
- [Libvirt Hooks](#libvirt-hooks)
- [Automation Script](#automation-script)
- [Input Passthrough](#input-passthrough)
- [VM Spoofing](#vm-spoofing)
- [Audio](#audio)
- [AMD Reset](#amd-reset)
- [vBIOS](#vbios)

## IOMMU Setup

### BIOS
Enable **VT-d** (Intel) or **AMD-Vi**. Disable ReBAR if black screens (see [below](#resizable-bar)).

### Kernel Params
Auto-detect: `intel_iommu=on iommu=pt` (Intel) or `amd_iommu=on iommu=pt` (AMD).

| Bootloader | File | Edit & Regenerate |
|------------|------|-------------------|
| GRUB | `/etc/default/grub` | Append to `GRUB_CMDLINE_LINUX_DEFAULT`; `grub-mkconfig -o /boot/grub/grub.cfg` |
| systemd-boot | `/boot/loader/entries/*.conf` | Append to `options` line |

Reboot. Verify: `dmesg | grep -i iommu` (expect "enabled" or "loaded").

### Groups
List script:
```bash
shopt -s nullglob
for g in /sys/kernel/iommu_groups/*; do
  echo "Group ${g##*/}:"
  for d in "$g"/devices/*; do echo -e "\t$(lspci -nns ${d##*/})"; done
done
```
Isolate non-unique groups with ACS override (ArchWiki).

## Resizable BAR
Kernel 6.1+ enables perf boost. BIOS: on. For AMD RX 6000 (e.g., 6700XT 0x73bf), add udev:
```
/etc/udev/rules.d/01-amd.rules
```
```
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource0_resize}="14"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x1002", ATTR{device}=="0x73bf", ATTR{resource2_resize}="8"
```
`udevadm control --reload`.

## Packages

| Distro | Command |
|--------|---------|
| Gentoo | `emerge --ask=n qemu libvirt virt-manager ebtables dnsmasq swtpm` |
| Arch | `pacman -Syu --needed qemu libvirt edk2-ovmf virt-manager dnsmasq ebtables iptables-nft` |
| Fedora | `dnf update -y && dnf group install -y --with-optional virtualization && dnf install -y edk2-ovmf swtpm` |
| Ubuntu | `add-apt-repository universe -y; apt update && apt install -y qemu-kvm libvirt-daemon-system virt-manager ovmf bridge-utils swtpm-tools` |

## Services
```bash
systemctl enable --now libvirtd
virsh net-start default; virsh net-autostart default
```
Add user: `usermod -aG libvirt,kvm,input $USER`. Log out/in.

## Guest VM
In virt-manager:
- Chipset: **Q35**, Firmware: **OVMF UEFI**.
- CPU: **host-passthrough** (match topology).
- Disk/NIC: **virtio** (use [virtio-win ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso) for Windows).
- Remove ISO post-install.


## PCI Attachment
Remove QXL/Spice. Add **PCI Host Device** for GPU (VGA) + Audio.

## Libvirt Hooks
Automate bind/unbind. Skip EFI FB for AMD 6000; unload host drivers.

Main hook: `/etc/libvirt/hooks/qemu` (executable):
```bash
#!/bin/bash
GUEST_NAME="$1" HOOK_NAME="$2" STATE_NAME="$3" MISC="${@:4}"
BASEDIR="$(dirname $0)" HOOKPATH="$BASEDIR/qemu.d/$GUEST_NAME/$HOOK_NAME/$STATE_NAME"
set -e
logger "libvirt-hook: $GUEST_NAME $HOOK_NAME $STATE_NAME"
if [ -f "$HOOKPATH" ]; then "$HOOKPATH" "$@"
elif [ -d "$HOOKPATH" ]; then
  find -L "$HOOKPATH" -maxdepth 1 -type f -executable -print0 | sort -z | xargs -0 "{}" "$@"
fi
```

Per-VM: `/etc/libvirt/hooks/qemu.d/$VM/prepare/begin/start.sh` & `release/end/stop.sh` (see script below).

## Automation Script
`vfio-setup.sh` (v3.2): Auto-detects OS/GPU/DE/VM, installs, configures hooks/VFIO/kernel. Root: `./vfio-setup.sh [--vm=win10] [--gpu=nvidia] [--de=plasma] [--dry-run]`.

[Full script here](vfio-setup.sh) (updated for Intel/AMD unbind, append params, vBIOS overwrite check).

## Input Passthrough
USB: Add **USB Host Device**. Evdev: XML `<qemu:commandline>` for `/dev/input/by-id/*event-*`; update `qemu.conf` ACL. Use virtio-input.

## VM Spoofing
- Hide KVM: `<kvm><hidden state='on'/></kvm>`.
- Hyper-V vendor: `<hyperv><vendor_id state='on' value='whatever'/></hyperv>`.

## Audio
PCI passthrough + PipeWire/JACK routing (ArchWiki). Alt: [Scream](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF#Scream).

## AMD Reset
RX 6000 Code 43: Install `vendor-reset` DKMS.
- Arch: AUR `vendor-reset-dkms-git`.
- Fedora: COPR `kylegospo/vendor-reset-dkms`.
- Ubuntu/Gentoo: Build/emerge.
Load in hooks: `modprobe vendor-reset`.

## vBIOS
Dump:
```bash
echo 1 > /sys/bus/pci/devices/0000:01:00.0/rom
cat /sys/bus/pci/devices/0000:01:00.0/rom > vbios.rom
echo 0 > /sys/bus/pci/devices/0000:01:00.0/rom
```
Patch (hex: trim pre-0x55 "VIDEO" for NVIDIA). XML: `<rom file='/path/vbios.rom'/>`.

## See Also
- [Troubleshooting](https://docs.google.com/document/d/17Wh9_5HPqAx8HHk-p2bGlR0E-65TplkG18jvM98I7V8)
- [joeknock90](https://github.com/joeknock90/Single-GPU-Passthrough)
- [YuriAlek](https://gitlab.com/YuriAlek/vfio)
- [wabulu](https://github.com/wabulu/Single-GPU-passthrough-amd-nvidia)
- [ArchWiki](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
- [Gentoo Wiki](https://wiki.gentoo.org/wiki/GPU_passthrough_with_libvirt_qemu_kvm)
- [PassthroughPost](https://passthroughpo.st/simple-per-vm-libvirt-hooks-with-the-vfio-tools-hook-helper/)
