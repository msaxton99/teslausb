#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "create-backingfiles: $1"
    return
  fi
  echo "create-backingfiles: $1"
}

log_progress "starting"

CAM_SIZE="$1"
MUSIC_SIZE="$2"
BOOMBOX_SIZE="$3"
LIGHTSHOW_SIZE="$4"
# strip trailing slash that shell autocomplete might have added
BACKINGFILES_MOUNTPOINT="${5/%\//}"
USE_EXFAT="$6"

log_progress "cam: $CAM_SIZE, music: $MUSIC_SIZE, boombox: $BOOMBOX_SIZE, lightshow: $LIGHTSHOW_SIZE mountpoint: $BACKINGFILES_MOUNTPOINT, exfat: $USE_EXFAT"

function first_partition_offset () {
  local filename="$1"
  local size_in_bytes
  local size_in_sectors
  local sector_size
  local partition_start_sector

  size_in_bytes=$(sfdisk -l -o Size -q --bytes "$1" | tail -1)
  size_in_sectors=$(sfdisk -l -o Sectors -q "$1" | tail -1)
  sector_size=$(( size_in_bytes / size_in_sectors ))
  partition_start_sector=$(sfdisk -l -o Start -q "$1" | tail -1)

  echo $(( partition_start_sector * sector_size ))
}

# Note that this uses powers-of-two rather than the powers-of-ten that are
# generally used to market storage.
function dehumanize () {
  echo $(($(echo "$1" | sed 's/GB/G/;s/MB/M/;s/KB/K/;s/G/*1024M/;s/M/*1024K/;s/K/*1024/')))
}

function is_percent() {
  echo "$1" | grep '%' > /dev/null
}

available_space () {
  freespace=$(df --output=avail --block-size=1K "$BACKINGFILES_MOUNTPOINT/" | tail -n 1)
  # leave 10 GB of free space for filesystem bookkeeping and snapshotting
  # (in kilobytes so 10M KB)
  padding=$(dehumanize "10M")
  echo $((freespace-padding))
}

function calc_size () {
  local requestedsize="$1"
  local availablesize
  availablesize="$(available_space)"
  if [ "$availablesize" -lt 0 ]
  then
    echo "0"
    return
  fi
  if is_percent "$requestedsize"
  then
    local percent=${requestedsize//%/}
    requestedsize="$(( availablesize * percent / 100 ))"
  else
    requestedsize="$(( $(dehumanize $requestedsize) / 1024 ))"
  fi
  if [ "$requestedsize" -gt "$availablesize" ]
  then
    requestedsize="$availablesize"
  fi
  echo "$requestedsize"
}

function add_drive () {
  local name="$1"
  local label="$2"
  local size="$3"
  local filename="$4"
  local useexfat="$5"

  log_progress "Allocating ${size}K for $filename..."
  fallocate -l "$size"K "$filename"
  if [ "$useexfat" = true  ]
  then
    echo "type=7" | sfdisk "$filename" > /dev/null
  else
    echo "type=c" | sfdisk "$filename" > /dev/null
  fi

  local partition_offset
  partition_offset=$(first_partition_offset "$filename")

  loopdev=$(losetup -o "$partition_offset" -f --show "$filename")
  log_progress "Creating filesystem with label '$label'"
  if [ "$useexfat" = true  ]
  then
    mkfs.exfat "$loopdev" -L "$label"
  else
    mkfs.vfat "$loopdev" -F 32 -n "$label"
  fi
  losetup -d "$loopdev"

  local mountpoint=/mnt/"$name"

  if [ ! -e "$mountpoint" ]
  then
    mkdir "$mountpoint"
  fi
}

function check_for_exfat_support () {
  # First check for built-in ExFAT support
  # If that fails, check for an ExFAT module
  # in this last case exfat doesn't appear
  # in /proc/filesystems if the module is not loaded.
  if grep -q exfat /proc/filesystems &> /dev/null
  then
    return 0;
  elif modprobe -n exfat &> /dev/null
  then
    return 0;
  else 
    return 1;  
  fi
}

CAM_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/cam_disk.bin"
MUSIC_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/music_disk.bin"
BOOMBOX_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/boombox_disk.bin"
LIGHTSHOW_DISK_FILE_NAME="$BACKINGFILES_MOUNTPOINT/lightshow_disk.bin"
# delete existing files, because fallocate doesn't shrink files, and
# because they interfere with the percentage-of-free-space calculation
if [ -e "$CAM_DISK_FILE_NAME" ] || [ -e "$MUSIC_DISK_FILE_NAME" ] || [ -e "$BOOMBOX_DISK_FILE_NAME" ] || [ -e "$LIGHTSHOW_DISK_FILE_NAME" ] || [ -e "$BACKINGFILES_MOUNTPOINT/snapshots" ]
then
  if [ -t 0 ]
  then
    read -r -p 'Delete snapshots and recreate recording and music drives? (yes/cancel)' answer
    case ${answer:0:1} in
      y|Y )
      ;;
      * )
        log_progress "aborting"
        exit
      ;;
    esac
  fi
fi
killall archiveloop || true
/root/bin/disable_gadget.sh || true
umount -d /mnt/cam || true
umount -d /mnt/music || true
umount -d /mnt/boombox || true
umount -d /mnt/lightshow || true
umount -d /backingfiles/snapshots/snap*/mnt || true
rm -f "$CAM_DISK_FILE_NAME"
rm -f "$MUSIC_DISK_FILE_NAME"
rm -f "$BOOMBOX_DISK_FILE_NAME"
rm -f "$LIGHTSHOW_DISK_FILE_NAME"
rm -rf "$BACKINGFILES_MOUNTPOINT/snapshots"

# Check if kernel supports ExFAT 
if ! check_for_exfat_support
then
  if [ "$USE_EXFAT" = true ]
  then
    log_progress "kernel does not support ExFAT FS. Reverting to FAT32."
    USE_EXFAT=false
  fi
else
  # install exfatprogs if needed
  if ! hash mkfs.exfat &> /dev/null
  then
    /root/bin/remountfs_rw
    if ! apt install -y exfatprogs
    then
      log_progress "kernel supports ExFAT, but exfatprogs package does not exist."
      if [ "$USE_EXFAT" = true ]
      then
        log_progress "Reverting to FAT32"
        USE_EXFAT=false
      fi
    fi
  fi
fi

# some distros don't include mkfs.vfat
if ! hash mkfs.vfat
then
  apt-get -y --force-yes install dosfstools
fi

CAM_DISK_SIZE="$(calc_size "$CAM_SIZE")"
MUSIC_DISK_SIZE="$(calc_size "$MUSIC_SIZE")"
BOOMBOX_DISK_SIZE="$(calc_size "$BOOMBOX_SIZE")"
LIGHTSHOW_DISK_SIZE="$(calc_size "$LIGHTSHOW_SIZE")"

add_drive "cam" "CAM" "$CAM_DISK_SIZE" "$CAM_DISK_FILE_NAME" "$USE_EXFAT"
log_progress "created camera backing file"

REMAINING_SPACE="$(available_space)"

if [ "$CAM_SIZE" = "100%" ]
then
  MUSIC_DISK_SIZE=0
elif [ "$MUSIC_DISK_SIZE" -gt "$REMAINING_SPACE" ]
then
  MUSIC_DISK_SIZE="$REMAINING_SPACE"
fi

if [ "$REMAINING_SPACE" -ge 1024 ] && [ "$MUSIC_DISK_SIZE" -gt 0 ]
then
  add_drive "music" "MUSIC" "$MUSIC_DISK_SIZE" "$MUSIC_DISK_FILE_NAME" "$USE_EXFAT"
  log_progress "created music backing file"
fi

REMAINING_SPACE="$(available_space)"
if [ "$BOOMBOX_DISK_SIZE" -gt "$REMAINING_SPACE" ]
then
  BOOMBOX_DISK_SIZE="$REMAINING_SPACE"
fi

if [ "$REMAINING_SPACE" -ge 1024 ] && [ "$BOOMBOX_DISK_SIZE" -gt 0 ]
then
  add_drive "boombox" "BOOMBOX" "$BOOMBOX_DISK_SIZE" "$BOOMBOX_DISK_FILE_NAME" "$USE_EXFAT"
  log_progress "created boombox backing file"
fi

REMAINING_SPACE="$(available_space)"
if [ "$LIGHTSHOW_DISK_SIZE" -gt "$REMAINING_SPACE" ]
then
  LIGHTSHOW_DISK_SIZE="$REMAINING_SPACE"
fi

if [ "$REMAINING_SPACE" -ge 1024 ] && [ "$LIGHTSHOW_DISK_SIZE" -gt 0 ]
then
  add_drive "lightshow" "LIGHTSHOW" "$LIGHTSHOW_DISK_SIZE" "$LIGHTSHOW_DISK_FILE_NAME" "$USE_EXFAT"
  log_progress "created lightshow backing file"
fi
log_progress "done"
