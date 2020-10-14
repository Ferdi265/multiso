# `multiso`

A script to create a simple bootable USB drive capable of booting more than one
distro.

## Usage

```
usage: multiso.sh [command]

commands:
 - partition DEVICE .... partition device for multiso
 - install DEVICE ...... install GRUB and multiso config on device
```

## Partition Layout

This script partitions the drive into a hybrid GPT / MBR partition scheme, with
both x86_64-efi and i386-pc GRUB installed. The partitions created are:

- 1: BIOS boot partition (1M, for i386-pc GRUB)
- 2: EFI system partition (50M, for x86_64-efi GRUB, labeled "MULTEFI")
- 3: FAT32 data partition (rest, for ISOs and GRUB config, labeled "MULTISO")

## Installing

To install `multiso` on a device `/dev/sdX`, you need to run the following
commands:

- `multiso.sh partition /dev/sdX`
  On devices with a broken or unrecognized partition table this might fail on
  first run. Rerun this command once, and it should go through without errors.
- `multiso.sh install /dev/sdX`

The partition label for the two partitions can be adjusted with the
`MULTISO_ISO_LABEL` and `MULTISO_EFI_LABEL` environment variables.

## Adding ISOs

Just put your ISOs into the `iso/` folder in the "MULTISO" partition. You will
need to adjust the configuration in `grub/grub.cfg` to add the correct menu
entry.

Since many distributions have very similar folder structure, you will often only
need to specify the kernel and initramfs paths. For the first image with a
particular structure, you will also have to add a "boot helper" function that
sets the right kernel parameters. Here is an example configuration for Ubuntu:

```
# ISO boot helpers -------------------------------------------------------------

function iso_boot_ubuntu {
    linux $linux_path iso-scan/filename="$iso_file" file=/cdrom/preseed/ubuntu.seed maybe-ubiquity $linux_options
}

# ISO menu entries -------------------------------------------------------------

set iso_name=ubuntu-20.04
set linux_path=/casper/vmlinuz
set initrd_path=/casper/initrd
set intel_ucode_path=
set amd_ucode_path=
iso_menuentry iso_boot_ubuntu

# ------------------------------------------------------------------------------
```

## Dependencies

This script needs the following programs to work:

- `sudo`
- `sgdisk`
- `partprobe`
- `mkfs.fat`
- `mount`
- `umount`
- `grub-install`
- `mktemp`
