#!/usr/bin/env bash
# Minimal, mostly automatic Gentoo amd64 installer for howl@brute.
# WARNING: the selected disk is repartitioned and ALL data on it is destroyed.
set -Eeuo pipefail
umask 077

readonly TARGET=/mnt/gentoo
readonly STAGE_BASE=https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc
readonly HOSTNAME=brute
readonly USERNAME=howl
readonly TIMEZONE=America/Edmonton
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup_secrets() {
  rm -f "$TARGET/root/.installer-root-pass" "$TARGET/root/.installer-user-pass" 2>/dev/null || true
}
trap cleanup_secrets EXIT
trap 'die "Installer interrupted at line $LINENO. The target may be partially installed; inspect it before rerunning."' INT TERM
[[ $EUID -eq 0 ]] || die "Run this installer as root from a Gentoo-compatible live environment."
[[ -d /sys/firmware/efi ]] || die "This installer expects the live environment to be booted in UEFI mode. Reboot the USB in UEFI mode and retry."
mountpoint -q "$TARGET" && die "$TARGET is already mounted. Reboot the live USB or unmount the previous target before starting over."

for cmd in parted lsblk blkid blockdev partprobe udevadm mkfs.fat mkfs.ext4 mkswap swapon mount umount mountpoint findmnt chroot curl wget tar awk sed; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required host command missing: $cmd"
done
log "Checking internet access before touching the target disk"
curl -fsSI --connect-timeout 10 --max-time 20 https://distfiles.gentoo.org/ >/dev/null || die "No working HTTPS connection to distfiles.gentoo.org. Connect to Wi-Fi with nmtui, then rerun the installer. No disk has been changed."
log "Gentoo OpenRC installer for ${USERNAME}@${HOSTNAME}"
printf 'This will install a minimal Gentoo desktop-ready base with OpenRC, ext4, GRUB, dracut and NetworkManager.\n'
printf 'Timezone: %s | EFI: 1 GiB | Swap: 4 GiB | Root + home: remaining space\n\n' "$TIMEZONE"
# Select a non-removable whole disk automatically when there is only one candidate.
mapfile -t DISKS < <(lsblk -dpno NAME,TYPE,RM | awk '$2 == "disk" && $3 == 0 {print $1}')
((${#DISKS[@]} > 0)) || die "No non-removable disks detected."
printf 'Detected disks:\n'
lsblk -dpno NAME,SIZE,MODEL,TRAN,RM
if ((${#DISKS[@]} == 1)); then
  DISK=${DISKS[0]}
  printf '\nOnly one non-removable disk detected; selecting %s automatically.\n' "$DISK"
else
  printf '\nMultiple disks detected. Enter the target disk (for example /dev/nvme0n1): '
  read -r DISK
fi
[[ -b "$DISK" ]] || die "Not a valid block device: $DISK"
[[ "$(lsblk -dn -o TYPE "$DISK")" == disk ]] || die "$DISK is not a whole disk."
# Refuse to wipe a disk with mounted partitions or active swap.
if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q '[^[:space:]]'; then
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
  die "The selected disk has mounted filesystems. Unmount them before running the installer."
fi
while IFS= read -r dev; do
  [[ -n "$dev" ]] || continue
  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$dev"; then
    die "Swap is active on $dev. Disable it before continuing."
  fi
done < <(lsblk -nrpo NAME "$DISK")
DISK_BYTES=$(blockdev --getsize64 "$DISK")
(( DISK_BYTES >= 16000000000 )) || die "Disk is too small for the selected 1 GiB EFI + 4 GiB swap layout."

printf '\nSelected disk: %s (%s)\n' "$DISK" "$(lsblk -dn -o SIZE,MODEL "$DISK")"
printf 'The entire disk will be erased. Type the exact device path to confirm: '
read -r CONFIRM_DISK
[[ "$CONFIRM_DISK" == "$DISK" ]] || die "Disk confirmation did not match. Nothing was changed."
read -r -s -p "Password for root: " ROOT_PASS; printf '\n'
read -r -s -p "Password for user ${USERNAME}: " USER_PASS; printf '\n'
[[ -n "$ROOT_PASS" && -n "$USER_PASS" ]] || die "Passwords cannot be empty."
[[ "$ROOT_PASS" != *$'\n'* && "$USER_PASS" != *$'\n'* ]] || die "Passwords cannot contain newline characters."
unset CONFIRM_DISK
# Partition naming differs between NVMe/MMC and SATA/SAS disks.
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  EFI_PART="${DISK}p1"; SWAP_PART="${DISK}p2"; ROOT_PART="${DISK}p3"
else
  EFI_PART="${DISK}1"; SWAP_PART="${DISK}2"; ROOT_PART="${DISK}3"
fi
log "Partitioning $DISK (GPT)"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart SWAP linux-swap 1025MiB 5121MiB
parted -s "$DISK" mkpart ROOT ext4 5121MiB 100%
partprobe "$DISK"
udevadm settle
for part in "$EFI_PART" "$SWAP_PART" "$ROOT_PART"; do
  for _ in {1..20}; do [[ -b "$part" ]] && break; sleep 1; done
  [[ -b "$part" ]] || die "Partition did not appear: $part"
done
log "Formatting ext4, EFI and swap"
mkfs.fat -F32 "$EFI_PART"
mkswap "$SWAP_PART"
mkfs.ext4 -F -m 1 "$ROOT_PART"
swapon "$SWAP_PART"
mountpoint -q "$TARGET" && die "$TARGET is already mounted."
mkdir -p "$TARGET"
mount -o noatime "$ROOT_PART" "$TARGET"
mkdir -p "$TARGET/boot"
mount "$EFI_PART" "$TARGET/boot"
log "Downloading and extracting the official Gentoo OpenRC Stage 3"
STAGE_FILE=$(curl -fsSL "$STAGE_BASE/latest-stage3-amd64-openrc.txt" | awk '$1 ~ /^stage3-amd64-openrc-.*\.tar\.xz$/ {print $1; exit}')
[[ -n "$STAGE_FILE" ]] || die "Could not find the current OpenRC Stage 3 tarball."
printf 'Stage 3: %s\n' "$STAGE_FILE"
wget -q --show-progress -O "$TARGET/$STAGE_FILE" "$STAGE_BASE/$STAGE_FILE"
tar xpf "$TARGET/$STAGE_FILE" -C "$TARGET" --xattrs-include='*' --numeric-owner
rm -f "$TARGET/$STAGE_FILE"
# Store credentials only after Stage 3 extraction so the archive cannot overwrite them.
install -d -m 0700 "$TARGET/root"
printf '%s' "$ROOT_PASS" > "$TARGET/root/.installer-root-pass"
printf '%s' "$USER_PASS" > "$TARGET/root/.installer-user-pass"
chmod 0600 "$TARGET/root/.installer-root-pass" "$TARGET/root/.installer-user-pass"
unset ROOT_PASS USER_PASS
log "Preparing chroot"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
mount -t proc /proc "$TARGET/proc"
mount --rbind /sys "$TARGET/sys"
mount --make-rslave "$TARGET/sys"
mount --rbind /dev "$TARGET/dev"
mount --make-rslave "$TARGET/dev"
mkdir -p "$TARGET/sys/firmware/efi/efivars"
mountpoint -q "$TARGET/sys/firmware/efi/efivars" || mount -t efivarfs efivarfs "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

cat > "$TARGET/root/install-in-chroot.sh" <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HOSTNAME=brute
USERNAME=howl
TIMEZONE=America/Edmonton
ROOT_UUID='__ROOT_UUID__'
EFI_UUID='__EFI_UUID__'
SWAP_UUID='__SWAP_UUID__'

ROOT_PASS=$(cat /root/.installer-root-pass)
USER_PASS=$(cat /root/.installer-user-pass)
cleanup_chroot_secrets() {
  unset ROOT_PASS USER_PASS
  rm -f /root/.installer-root-pass /root/.installer-user-pass
}
trap cleanup_chroot_secrets EXIT

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
log "Setting timezone, hostname and locale"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1 localhost
127.0.1.1 ${HOSTNAME}
::1 localhost
EOF_HOSTS
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
cat > /etc/conf.d/hwclock <<'EOF_CLOCK'
clock="UTC"
EOF_CLOCK
cat > /etc/conf.d/keymaps <<'EOF_KEYMAP'
keymap="us"
EOF_KEYMAP
cat > /etc/locale.gen <<'EOF_LOCALE'
en_US.UTF-8 UTF-8
EOF_LOCALE
log "Syncing Portage and selecting the desktop OpenRC profile"
emerge-webrsync
eselect profile set default/linux/amd64/23.0/desktop
# Desktop profile is appropriate for graphical window managers (X11 or Wayland),
# but does not install a desktop environment.
mkdir -p /etc/portage/package.use
# Work around the documented Pillow truetype USE-flag dependency cycle.
printf 'dev-python/pillow -truetype\n' > /etc/portage/package.use/pillow-cycle
cat > /etc/portage/make.conf <<'EOF_MAKE'
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j8 -l8"
EMERGE_DEFAULT_OPTS="--jobs=1 --load-average=8"
PORTAGE_LOGDIR="/var/log/portage"
CHOST="x86_64-pc-linux-gnu"
RUSTFLAGS="-C target-cpu=native"
USE="X wayland dbus opengl networkmanager dist-kernel"
VIDEO_CARDS="nvidia"
LINGUAS="en"
ACCEPT_LICENSE="*"
EOF_MAKE
# Gentoo's installkernel uses Dracut to generate an initramfs for the binary kernel.
cat > /etc/portage/package.use/installkernel <<'EOF_INSTALLKERNEL'
sys-kernel/installkernel dracut
EOF_INSTALLKERNEL
cat > /etc/portage/package.use/networkmanager <<'EOF_NETWORKMANAGER'
net-misc/networkmanager wifi
net-wireless/wpa_supplicant dbus
EOF_NETWORKMANAGER
cat > /etc/portage/package.use/nvidia <<'EOF_NVIDIA_USE'
x11-drivers/nvidia-drivers kernel-open wayland
EOF_NVIDIA_USE
cat > /etc/portage/package.use/audio <<'EOF_AUDIO_USE'
media-video/pipewire sound-server pulseaudio pipewire-alsa dbus
media-video/wireplumber dbus
EOF_AUDIO_USE
mkdir -p /var/log/portage
locale-gen
eselect locale set en_US.utf8

log "Updating the base system"
emerge --ask=n --update --deep --newuse @world
log "Installing kernel, initramfs generator, NVIDIA driver, PipeWire audio, bootloader and requested tools"
emerge --ask=n --verbose \
  media-video/pipewire \
  media-video/wireplumber \
  media-libs/libpulse \
  media-plugins/alsa-plugins \
  sys-kernel/gentoo-kernel-bin \
  sys-kernel/linux-firmware \
  x11-drivers/nvidia-drivers \
  sys-boot/grub \
  sys-boot/efibootmgr \
  net-misc/networkmanager \
  sys-apps/dbus \
  sys-auth/elogind \
  net-wireless/wpa_supplicant \
  app-admin/doas \
  dev-vcs/git \
  app-editors/vis \
  net-misc/curl \
  net-misc/wget \
  app-misc/fastfetch \
  sys-process/btop
log "Configuring NVIDIA DRM for X11 and Wayland"
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/nvidia.conf <<'EOF_NVIDIA_DRACUT'
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF_NVIDIA_DRACUT
# The NVIDIA ebuild supplies its own Dracut configuration. Rebuild the
# initramfs after the driver is installed so it contains the matching modules.
dracut --regenerate-all --force
# Enable NVIDIA DRM KMS, needed by modern Wayland compositors.
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub
else
  printf '\nGRUB_CMDLINE_LINUX_DEFAULT="nvidia_drm.modeset=1 nvidia_drm.fbdev=1"\n' >> /etc/default/grub
fi
log "Writing fstab"
cat > /etc/fstab <<EOF_FSTAB
UUID=${ROOT_UUID}  /      ext4  noatime  0 1
UUID=${EFI_UUID}   /boot  vfat  noatime  0 2
UUID=${SWAP_UUID}  none   swap  sw       0 0
EOF_FSTAB
log "Creating user and configuring doas"
for group in wheel video input plugdev; do
  getent group "$group" >/dev/null 2>&1 || groupadd "$group"
done
useradd -m -G wheel,video,input,plugdev -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chpasswd
printf 'root:%s\n' "$ROOT_PASS" | chpasswd
cat > /etc/doas.conf <<'EOF_DOAS'
permit persist :wheel
EOF_DOAS
chmod 0400 /etc/doas.conf
log "Configuring OpenRC services"
rc-update add dbus default
rc-update add NetworkManager default
# elogind provides login-session integration and XDG_RUNTIME_DIR support.
rc-update add elogind boot
[[ -x /etc/init.d/udev ]] && rc-update add udev sysinit
[[ -x /etc/init.d/udev-trigger ]] && rc-update add udev-trigger sysinit
if command -v dbus-uuidgen >/dev/null 2>&1; then
  dbus-uuidgen --ensure=/etc/machine-id
fi

log "Installing GRUB for UEFI"
mkdir -p /boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --recheck
grub-mkconfig -o /boot/grub/grub.cfg
log "Checking kernel, initramfs, fstab and bootloader"
KERNEL=$(find /boot -maxdepth 1 -type f \( -name 'vmlinuz*' -o -name 'kernel-*' \) -print -quit)
INITRAMFS=$(find /boot -maxdepth 1 -type f \( -name 'initramfs*' -o -name 'initrd*' \) -print -quit)
[[ -n "$KERNEL" ]] || { echo "No kernel image found in /boot" >&2; exit 1; }
[[ -n "$INITRAMFS" ]] || { echo "No Dracut initramfs found in /boot" >&2; exit 1; }
[[ -s /boot/grub/grub.cfg ]] || { echo "GRUB configuration is missing or empty" >&2; exit 1; }
grep -q 'menuentry' /boot/grub/grub.cfg || { echo "No GRUB menu entries were generated" >&2; exit 1; }
[[ -s /etc/fstab ]] || { echo "/etc/fstab is missing" >&2; exit 1; }
[[ -x /sbin/init ]] || { echo "/sbin/init is missing" >&2; exit 1; }
printf '\nKernel: %s\nInitramfs: %s\n' "$KERNEL" "$INITRAMFS"
printf '\nInstallation inside chroot completed successfully.\n'
CHROOT_SCRIPT
# Inject UUIDs as shell-safe UUID strings (UUID characters are hexadecimal and hyphens only).
sed -i \
  -e "s/__ROOT_UUID__/${ROOT_UUID}/" \
  -e "s/__EFI_UUID__/${EFI_UUID}/" \
  -e "s/__SWAP_UUID__/${SWAP_UUID}/" \
  "$TARGET/root/install-in-chroot.sh"
chmod 0700 "$TARGET/root/install-in-chroot.sh"

log "Running the installation inside the new system (this can take a while)"
chroot "$TARGET" /bin/bash -lc /root/install-in-chroot.sh

cleanup_secrets
rm -f "$TARGET/root/install-in-chroot.sh"
log "Installation completed"
printf 'Installed system: %s@%s\n' "$USERNAME" "$HOSTNAME"
printf 'Disk: %s | EFI: %s | Swap: %s | Root: %s\n' "$DISK" "$EFI_PART" "$SWAP_PART" "$ROOT_PART"
printf '\nBefore rebooting, unmount the target:\n'
printf '  umount -R %s\n  swapoff %s\n  reboot\n' "$TARGET" "$SWAP_PART"
printf '\nNVIDIA is configured for X11/Wayland. PipeWire + WirePlumber are installed. Start them from your WM session with:\n'
printf '  pipewire &\n  wireplumber &\n  pipewire-pulse &\n'
printf 'A window manager can be installed separately.\n'
