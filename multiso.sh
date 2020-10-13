#!/bin/bash

# script installation location
SCRIPT_FILE="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_FILE")"

# environment variable defaults
MULTISO_LOG_DEBUG=${MULTISO_LOG_DEBUG:-1}
MULTISO_ISO_LABEL=${MULTISO_ISO_LABEL:-MULTISO}
MULTISO_EFI_LABEL=${MULTISO_EFI_LABEL:-MULTEFI}

# output color variables
# (see 'man console_codes', section 'ECMA-48 Set Graphics Rendition')
R=$'\e[1;31m'
G=$'\e[1;32m'
Y=$'\e[1;33m'
B=$'\e[1;34m'
W=$'\e[1;37m'
N=$'\e[0m'

# utility functions

log-error() {
    echo "${R}error:${N} $1"
}

log-warn() {
    echo "${Y}warn:${N} $1"
}

log-info() {
    echo "${W}info:${N} $1"
}

log-debug() {
    if [[ $MULTISO_LOG_DEBUG -eq 1 ]]; then
        echo "${B}debug:${N} $1"
    fi
}

check-installed() {
    type -p "$1" >/dev/null
    if [[ $? -ne 0 ]]; then
        log-error "the '$1' command is missing!"
        MISSING_PROGRAMS=1
    fi
}

noisy-rm-dir() {
    if [[ -d "$1" ]]; then
        log-debug "removing '$1'"
        rm -rf "$1"
    fi
}

expect-argc() {
    expected="$1"
    actual="$2"

    if [[ "$expected" -ne "$actual" ]]; then
        log-error "command '$cmd' expects $expected arguments, $actual given"
        multiso-help
        exit 1
    fi
}

sudo-test() {
    sudo test "$@"
    if [[ $? -eq 0 ]]; then
        return 1
    else
        return 0
    fi
}

TEMP_DIR_LIST=()
create-temp-dir() {
    TEMP_DIR=$(mktemp -d -t 'multiso.tmp.XXXXXXXXXX')
    TEMP_DIR_LIST+=( "$TEMP_DIR" )
    trap cleanup-temp-and-mounts EXIT

    log-debug "creating temporary directory '$TEMP_DIR'"
}

MOUNT_LIST=()
mount-partition() {
    dev="$1"
    mountpoint="$2"
    MOUNT_LIST+=( "$dev" )
    trap cleanup-temp-and-mounts EXIT

    log-debug "mounting '$dev' at '$mountpoint'"
    sudo mount "$dev" "$mountpoint"

    if [[ $? -ne 0 ]]; then
        log-error "failed to mount '$dev'"
        exit 1
    fi
}

cleanup-temp-and-mounts() {
    if [[ ${#MOUNT_LIST[@]} -gt 0 ]]; then
        log-debug "unmounting partitions"

        for DEV in "${MOUNT_LIST[@]}"; do
            log-debug "unmounting '$DEV'"
            sudo umount "$DEV"
        done
    fi

    log-debug "removing temporary files"

    for TEMP_DIR in "${TEMP_DIR_LIST[@]}"; do
        noisy-rm-dir "$TEMP_DIR"
    done
}

# check for needed programs

MISSING_PROGRAMS=0
check-installed sudo
check-installed sgdisk
check-installed partprobe
check-installed mkfs.fat
check-installed mount
check-installed umount
check-installed grub-install
check-installed mktemp

if [[ $MISSING_PROGRAMS -ne 0 ]]; then
    log-error "aborting due to missing required commands"
    exit 1
fi

# commands

multiso-partition() {
    disk="$1"

    log-info "checking file '$disk'..."

    log-debug "checking for root rights"
    if sudo-test x; then
        log-error "need root rights to check disk"
        exit 1
    fi

    log-debug "checking if '$disk' is a block device"
    if sudo-test -b "$disk"; then
        log-error "'$disk' is not a block device"
        exit 1
    fi

    log-debug "checking if '$disk' is writable by root"
    if sudo-test -w "$disk"; then
        log-error "cannot write to '$disk'"
        exit 1
    fi

    log-warn "this will overwrite everything on '$disk'"
    echo -n "proceed? [yes/no] "
    read answer

    if [[ "$answer" != "yes" ]]; then
        log-error "aborted, exiting..."
        exit 1
    fi

    log-info "removing old partition table"
    sudo sgdisk -Z "$disk"

    if [[ $? -ne 0 ]]; then
        log-error "failed to remove partition table"
        exit 1
    fi

    log-info "creating new partitions"
    sudo sgdisk -n 1:2M:+1M -t 1:EF02 -n 2:0:+50M -t 2:EF00 -N 3 -t 3:0700 -h 1:2:3 -p "$disk"

    if [[ $? -ne 0 ]]; then
        log-error "failed to create new partition table"
        exit 1
    fi

    log-info "informing the kernel of new partition tables"
    sudo partprobe

    if [[ $? -ne 0 ]]; then
        log-error "failed to probe partitions"
        exit 1
    fi

    efi_part="${disk}2"
    log-debug "checking if EFI partition '$efi_part' exists"
    if sudo-test -e "$efi_part"; then
        log-error "newly created EFI partition does not exist"
        exit 1
    fi

    iso_part="${disk}3"
    log-debug "checking if ISO partition '$iso_part' exists"
    if sudo-test -e "$iso_part"; then
        log-error "newly created ISO partition does not exist"
        exit 1
    fi

    log-info "creating filesystems"

    log-debug "creating FAT32 on '$efi_part'"
    sudo mkfs.fat -F32 -n "${MULTISO_EFI_LABEL}" "$efi_part"
    if [[ $? -ne 0 ]]; then
        log-error "failed to format EFI partition"
        exit 1
    fi

    log-debug "creating FAT32 on '$iso_part'"
    sudo mkfs.fat -F32 -n "${MULTISO_ISO_LABEL}" "$iso_part"
    if [[ $? -ne 0 ]]; then
        log-error "failed to format ISO partition"
        exit 1
    fi

    log-info "partitioning finished"
}

multiso-install() {
    disk="$1"

    log-info "checking file '$disk'..."

    if sudo-test x; then
        log-error "need root rights to check disk"
        exit 1
    fi

    if sudo-test -b "$disk"; then
        log-error "'$disk' is not a block device"
        exit 1
    fi

    efi_part="${disk}2"
    if sudo-test -e "$efi_part"; then
        log-error "EFI partition does not exist (maybe partition first?)"
        exit 1
    fi

    iso_part="${disk}3"
    if sudo-test -e "$iso_part"; then
        log-error "ISO partition does not exist (maybe partition first?)"
        exit 1
    fi

    create-temp-dir

    log-debug "creating mount points"
    mkdir "$TEMP_DIR/efi"
    mkdir "$TEMP_DIR/iso"

    log-info "mounting file systems"

    mount-partition "$efi_part" "$TEMP_DIR/efi"
    mount-partition "$iso_part" "$TEMP_DIR/iso"

    log-info "installing GRUB"

    sudo grub-install --target=x86_64-efi --efi-directory="$TEMP_DIR/efi" --boot-directory="$TEMP_DIR/iso" --removable --recheck
    if [[ $? -ne 0 ]]; then
        log-error "failed to install EFI GRUB"
        exit 1
    fi

    sudo grub-install --target=i386-pc "$disk" --boot-directory="$TEMP_DIR/iso" --recheck
    if [[ $? -ne 0 ]]; then
        log-error "failed to install BIOS GRUB"
        exit 1
    fi

    log-info "creating ISO folder"
    sudo mkdir "$TEMP_DIR/iso/iso"

    log-info "copying default configuration"
    sudo cp "$SCRIPT_DIR/grub.cfg" "$TEMP_DIR/iso/grub/grub.cfg"

    log-info "installation finished"
}

multiso-help() {
    echo "${W}usage:${N} $(basename "$0") [command]"
    echo
    echo "${W}commands:${N}"
    echo " - partition DEVICE .... partition device for multiso"
    echo " - install DEVICE ...... install GRUB and multiso config on device"
}

multiso-invalid-usage() {
    log-error "invalid usage"
    multiso-help
    exit 1
}

# invocation

if [[ $# -lt 1 ]]; then
    multiso-invalid-usage
fi

cmd="$1"
shift
case "$cmd" in
    partition) expect-argc 1 "$#"; multiso-partition "$1";;
    install) expect-argc 1 "$#"; multiso-install "$1";;
    help) expect-argc 0 "$#"; multiso-help;;
    *) multiso-invalid-usage;;
esac

exit 0
