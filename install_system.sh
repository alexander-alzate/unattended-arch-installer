#!/bin/bash

TRUE=`true`
FALSE=`false`

# Functions thanks to Philip Huppert (archvm.sh)
function announce {
	>&2 echo "$1... "
}

# Functions thanks to Philip Huppert (archvm.sh)
function check_fail {
	if [[  $1 -ne $TRUE  ]]; then
		>&2 echo "Fail!"
		exit 1
	else
		>&2 echo "Done!"
	fi
}

DISK="/dev/sda"
BOOT_PARTITION_SIZE=512M
SYSTEM_PARTITION_SIZE=50G

CRYPT_SWAP_NAME=crypt_swap
CRYPT_SWAP=/dev/mapper/$CRYPT_SWAP_NAME
CRYPT_TMP_NAME=crypt_tmp
CRYPT_TMP=/dev/mapper/$CRYPT_TMP_NAME

RAM_SIZE=`grep MemTotal /proc/meminfo | awk '{print $2}'`K

DEFAULT_LOCALE=en_US
DEFAULT_CHARSET=UTF8

CONSOLE_KEYMAP="es"

PACSTRAP="base base-devel grub openssh sudo vim"
HOSTNAME=workstation
TIMEZONE=America/Bogota


ROOT_PASSWORD=root
DEFAULT_USER=default
DEFAULT_USER_PASSOWRD=default
DEFAULT_USER_OPTIONS="-g user -G wheel"

[ -e /sys/firmware/efi/efivars ]; UEFI_SYSTEM=$?

announce "Checking internet connectivity"
ping -qc 3 www.google.com.co
check_fail $?

# Disk partition
announce "Performing disk partition"

if vgs | grep -q VG; then
	announce "Removing LVM Logical Volumes"
	for i in `lvs --noheadings | cut -d' ' -f3`; do
		lvremove -f $i
	done

	announce "Removing LVM Volume Groups"
	for i in `vgs --noheadings | cut -d' ' -f3`; do
		vgremove -f $i
	done

	announce "Removing LVM Physical Volumes"
	for i in `pvs --noheadings | cut -d' ' -f3`; do
		pvremove $i
	done
fi

if [[ $UEFI_SYSTEM -eq $TRUE ]]; then
	announce "Installing UEFI file system"
	PACSTRAP="$PACSTRAP efibootmgr"

	announce "Generating GUID Partition Table"
	sgdisk -Z "$DISK"
	check_fail $?

	announce "Generating ESP"
	sgdisk -n 1:2048:300M -c 1:EFI -t 1:EF00 "$DISK"
	check_fail $?

	announce "Generating Boot partition"
	BOOT_PARTITION="${DISK}2"
	sgdisk -n 2:+1:$BOOT_PARTITION_SIZE -c 2:Boot -t 1:8300 "$DISK"
	check_fail $?

	announce "Generating System partition"
	SYSTEM_PV="${DISK}3"
	sgdisk -n 3:+1:$SYSTEM_PARTITION_SIZE -c 2:System -t 2:8E00 "$DISK"
	check_fail $?

	announce "Generating Home partition"
	HOME_PV="${DISK}4"
	sgdisk -n 4:+1: -c 4:Home -t 3:8E00 "$DISK"
	check_fail $?
else
	announce "Installing BIOS file system"

	announce "Cleanning partition signature"
	wipefs -af "$DISK"
	check_fail $?

	announce "Generating Paritions"
	sfdisk -f "$DISK" <<-PARTITION_TABLE
		label: dos
		unit:sectors

		$DISK: start=2048 size=$BOOT_PARTITION_SIZE bootable type=83
		$DISK: size=$SYSTEM_PARTITION_SIZE type=8E
		$DISK: type=8E
	PARTITION_TABLE
	check_fail $?

	BOOT_PARTITION="${DISK}1"
	SYSTEM_PV="${DISK}2"
	HOME_PV="${DISK}3"
fi
announce "Reloading partition table"
partprobe $DISK
check_fail $?

announce "Generating LVM Volumes"

announce "Initializing Physical Volumes"
	pvcreate $SYSTEM_PV $HOME_PV
check_fail $?

announce "Generating System Volume Group"
vgcreate system_vg $SYSTEM_PV
check_fail $?

announce "Generating Home Volume Group"
vgcreate home_vg $HOME_PV
check_fail $?

announce "Generating System TMP Logical Volume"
lvcreate -L 2G system_vg -n tmp_lv
TMP_PARTITION=/dev/system_vg/tmp_lv
check_fail $?

announce "Generating System SWAP Logical Volume"
lvcreate -L "$RAM_SIZE" system_vg -n swap_lv
SWAP_PARTITION=/dev/system_vg/swap_lv
check_fail $?

announce "Generating System Root Logical Volume"
lvcreate -l 100%FREE system_vg -n root_lv
ROOT_PARTITION=/dev/system_vg/root_lv
check_fail $?

announce "Generating System Root Logical Volume"
lvcreate -l 100%FREE home_vg -n home_lv
HOME_PARTITION=/dev/home_vg/home_lv
check_fail $?

announce "Formatting partitions"

if [[ $UEFI_SYSTEM -eq $TRUE ]]; then
	announce "Formating ESP to FAT32"
	mkfs.vfat -n EFI -F 32 "${DISK}1"
	check_fail $?
fi

announce "Formating Boot partition to ext4"
mkfs.ext4 -L Boot "$BOOT_PARTITION"
check_fail $?

announce "Formating Root partition to ext4"
mkfs.ext4 -L Root "$ROOT_PARTITION"
check_fail $?

announce "Formating Home partition to ext4"
mkfs.ext4 -L Home "$HOME_PARTITION"
check_fail $?

announce "Mounting Root"
mount "$ROOT_PARTITION" /mnt
check_fail $?

announce "Generating /home and /boot folders"
mkdir -v /mnt/{home,boot}
check_fail $?

announce "Mounting Home partition"
mount "$HOME_PARTITION" /mnt/home
check_fail $?

announce "Mounting Boot partition"
mount "$BOOT_PARTITION" /mnt/boot
check_fail $?

if [[ $UEFI_SYSTEM -eq $TRUE ]]; then
	announce "Generating EFI folder"
	mkdir -v /mnt/boot/efi
	check_fail $?

	announce "Mounting ESP"
	mount "${DISK}1" /mnt/boot/efi
	check_fail $?
fi

announce "Installing System"
pacstrap /mnt $PACSTRAP
check_fail $?

announce "Generating fstab"
genfstab /mnt >> /mnt/etc/fstab
check_fail $?

announce "Generating crypttab"
cat <<CRYPTTAB >> /mnt/etc/crypttab

$CRYPT_SWAP_NAME $SWAP_PARTITION /dev/urandom swap,cipher=aes-cbc-essiv:sha256
$CRYPT_TMP_NAME $TMP_PARTITION /dev/urandom tmp,cipher=aes-cbc-essiv:sha256
CRYPTTAB
ckeck_fail $?

announce "Adding crypted devices to fstab"
cat <<FSTAB >> /mnt/etc/fstab

# SWAP
$CRYPT_SWAP none swap defaults 0 0

# tmp
$CRYPT_TMP /tmp tmpfs nodev,nosuid 0 0
FSTAB
check_fail $?

announce "Setting root password"
echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd
check_fail $?

announce "Configuring skel folder"
#cp -t /mnt/etc/skel /etc/skel/.bash* /etc/skel/*
find /etc/skel -mindepth 1 -maxdepth 1 -exec cp -fr {} /mnt/etc/skel \;
check_fail $?

announce "Installing root home"
#cp -t /mnt/root /etc/skel/.bash* /etc/skel/*
find /etc/skel -mindepth 1 -maxdepth 1 -exec cp -fr {} /mnt/root \;
check_fail $?

announce "Setting hostname"
echo "$HOSTNAME" > /mnt/etc/hostname
check_fail $?

announce "Setting Timezone"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
check_fail $?

announce "Enabling locales"
sed -i \
	-e 's/#\(en_US\.UTF\)/\1/' \
	-e 's/#\(es_CO\.UTF\)/\1/' \
	/mnt/etc/locale.gen
check_fail $?

announce "Configuring locales"
cat <<EOF > /mnt/etc/locale.conf
LANG="en_US.UTF-8"
LC_CTYPE="es_CO.UTF-8"
LC_NUMERIC="es_CO.UTF-8"
LC_TIME="es_CO.UTF-8"
LC_COLLATE="es_CO.UTF-8"
LC_MONETARY="es_CO.UTF-8"
LC_MESSAGES="en_US.UTF-8"
LC_PAPER="es_CO.UTF-8"
LC_NAME="es_CO.UTF-8"
LC_ADDRESS="es_CO.UTF-8"
LC_TELEPHONE="es_CO.UTF-8"
LC_MEASUREMENT="es_CO.UTF-8"
LC_IDENTIFICATION="es_CO.UTF-8"
EOF
check_fail $?

announce "Generating locales"
arch-chroot /mnt locale-gen
check_fail $?

announce "Configuring vconsole"
echo "KEYMAP=$CONSOLE_KEYMAP" > /mnt/etc/vconsole.conf
check_fail $?

announce "Configuring network"
arch-chroot /mnt systemctl enable dhcpcd
check_fail $?

if [[ $UEFI_SYSTEM -eq $TRUE ]]; then
	announce "Installing UEFI GRUB"
	arch-chroot /mnt grub-install --target=x86_64-efi \
		--efi-directory=/boot/efi --bootloader-id=grub
	check_fail $?

	announce "Installing EFI bootloader"
	EFI_PATH=/mnt/boot/efi/EFI
	mkdir $EFI_PATH/boot && cp $EFI_PATH/{grub/grub,boot/boot}x64.efi
	check_fail $?
else
	announce "Installing MBR GRUB"
	arch-chroot /mnt grub-install --target=i386-pc /dev/sda
	check_fail $?
fi

announce "Configuring GRUB defaults"
GRUB_DEFAULTS_PATH=/mnt/etc/default/grub
sed -i \
	-e 's/\(GRUB_TIMEOUT\).*$/\1=0/g' \
	-e 's/#\(GRUB_HIDDEN_TIMEOUT_QUIET\)/\1/g' \
	-e 's/#\(GRUB_DISABLE_LINUX_UUID\)/\1/g' \
	$GRUB_DEFAULTS_PATH
check_fail $?

announce "Installing GRUB"
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
check_fail $?

announce "Configuring mkinitcpio"
sed -i 's/filesystems/lvm2 \0/g' /mnt/etc/mkinitcpio.conf
check_fail $?

announce "Generating mkinitcpio"
arch-chroot /mnt mkinitcpio -p linux
check_fail $?

announce "Generating Default User: $DEFAULT_USER"
arch-chroot /mnt useradd -m $DEFAULT_USER_OPTIONS $DEFAULT_USER
check_fail $?

announce "Setting Default User password"
echo "$DEFAULT_USER:$DEFAULT_USER_PASSWORD" | arch-chroot /mnt chpasswd
check_fail $?

announce "Everything went fine! restarting the system"
sleep 2
systemctl reboot

