#!/bin/bash
# =====================================================================
#  INTEGRATED LINUX STORAGE MANAGER  (menu-driven, Bash only)
#  Project : Integrated Linux Storage Infrastructure (Ubuntu)
#  Covers  : partitions, LVM, snapshot, backup, restore, monitoring,
#            cron automation and logs.
#  Run     : sudo ./storage_manager.sh
#  Cron    : sudo ./storage_manager.sh --backup   (non-interactive)
#            sudo ./storage_manager.sh --monitor  (non-interactive)
# =====================================================================

# ---------- 1. SETTINGS (can be changed in one place) ----------
VG="${VG:-vg_storage}"
DATA_DIR="${DATA_DIR:-/mnt/data}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/backup}"
BACKUP_LOG="${BACKUP_LOG:-/var/log/backup.log}"
MONITOR_LOG="${MONITOR_LOG:-/var/log/storage_monitor.log}"
SCRIPT_PATH=$(readlink -f "$0")

# temporary files, removed automatically when the script ends
TMP=$(mktemp)
TMP2=$(mktemp)
trap 'rm -f "$TMP" "$TMP2"' EXIT

# ---------- 2. COLOURS (only when running in a terminal) ----------
if [ -t 1 ]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# ---------- 3. SMALL HELPER FUNCTIONS ----------
ok()    { echo "${GREEN}[OK]${RESET} $1"; }
err()   { echo "${RED}[ERROR]${RESET} $1"; }
warn()  { echo "${YELLOW}[WARNING]${RESET} $1"; }
pause() { echo; read -r -p "Press Enter to return to the menu..." _; }

# check that a command exists before using it
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Command '$1' is not installed."
    return 1
  fi
  return 0
}

# is the text a whole number?
is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

# is the text a safe name (letters, numbers, underscore)?
is_name() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

# does a logical volume exist in our volume group?
lv_exists() { lvs "$VG/$1" >/dev/null 2>&1; }

# free space (in MB) left in the volume group
free_mb() {
  local f
  f=$(vgs --noheadings --units m --nosuffix -o vg_free "$VG" 2>/dev/null)
  f=${f//[[:space:]]/}
  echo "${f%%[.,]*}"
}

# ---------- 4. MENU OPTIONS ----------

# 1) Show everything about the storage
show_overview() {
  echo "${BOLD}--- Disks and partitions ---${RESET}"
  lsblk
  if need pvs; then
    echo; echo "${BOLD}--- Physical volumes ---${RESET}"; pvs
    echo; echo "${BOLD}--- Volume group ---${RESET}"; vgs
    echo; echo "${BOLD}--- Logical volumes ---${RESET}"; lvs
  fi
  echo; echo "${BOLD}--- Mounted storage ---${RESET}"
  df -h "$DATA_DIR" "$BACKUP_DIR"
}

# 2) Partition a NEW empty disk and (optionally) add it to the volume group
do_partition() {
  local d rootsrc rootdisk count n c i s e start a pre j p
  echo "${BOLD}--- Create partitions on a NEW empty disk ---${RESET}"
  if ! need parted; then return; fi
  lsblk -d -o NAME,SIZE,TYPE
  read -r -p "Enter disk name (example: sdb): " d
  if ! [[ "$d" =~ ^[a-z0-9]+$ ]]; then err "Invalid disk name."; return; fi
  if [ ! -b "/dev/$d" ]; then err "/dev/$d does not exist."; return; fi

  rootsrc=$(findmnt -n -o SOURCE /)
  rootdisk=$(lsblk -no pkname "$rootsrc" 2>/dev/null)
  if [ "$d" = "$rootdisk" ]; then
    err "/dev/$d is the SYSTEM disk. Refusing to touch it."; return
  fi

  lsblk -n -o NAME "/dev/$d" > "$TMP"
  count=$(wc -l < "$TMP")
  if [ "$count" -gt 1 ]; then
    err "/dev/$d already has partitions. Only empty disks are allowed."; return
  fi

  read -r -p "How many partitions (1-4)? " n
  if ! [[ "$n" =~ ^[1-4]$ ]]; then err "Enter a number from 1 to 4."; return; fi

  warn "This will ERASE everything on /dev/$d"
  read -r -p "Type YES (capital letters) to continue: " c
  if [ "$c" != "YES" ]; then echo "Cancelled. Nothing was changed."; return; fi

  parted -s "/dev/$d" mklabel gpt
  i=0
  while [ "$i" -lt "$n" ]; do
    s=$(( i * 100 / n ))
    e=$(( (i + 1) * 100 / n ))
    if [ "$s" -eq 0 ]; then start="1MiB"; else start="${s}%"; fi
    parted -s "/dev/$d" mkpart primary "$start" "${e}%"
    parted -s "/dev/$d" set $(( i + 1 )) lvm on
    i=$(( i + 1 ))
  done
  partprobe "/dev/$d"; sleep 1
  ok "Partitions created on /dev/$d"
  lsblk "/dev/$d"

  read -r -p "Add these partitions to volume group $VG? (y/n): " a
  if [ "$a" = "y" ]; then
    case "$d" in
      *[0-9]) pre="${d}p" ;;
      *) pre="$d" ;;
    esac
    j=1
    while [ "$j" -le "$n" ]; do
      p="/dev/${pre}${j}"
      pvcreate -y "$p"
      if vgs "$VG" >/dev/null 2>&1; then vgextend "$VG" "$p"; else vgcreate "$VG" "$p"; fi
      j=$(( j + 1 ))
    done
    ok "Volume group $VG updated."
    vgs "$VG"
  fi
}

# 3) Create a new logical volume, format it, mount it, add to fstab
create_lv() {
  local name size free
  echo "${BOLD}--- Create a new logical volume ---${RESET}"
  read -r -p "Enter new volume name (letters, numbers, _): " name
  if ! is_name "$name"; then err "Invalid name. Use only letters, numbers and _."; return; fi
  read -r -p "Enter size in MB (example: 100): " size
  if ! is_num "$size"; then err "Size must be a whole number."; return; fi
  if [ "$size" -le 0 ]; then err "Size must be greater than 0."; return; fi
  if ! need lvcreate; then return; fi
  if lv_exists "$name"; then err "Volume '$name' already exists."; return; fi
  free=$(free_mb)
  if [ -z "$free" ]; then err "Volume group '$VG' not found."; return; fi
  if [ "$size" -gt "$free" ]; then err "Only ${free} MB free in $VG. Choose a smaller size."; return; fi

  if lvcreate -y -L "${size}M" -n "$name" "$VG"; then
    mkfs.ext4 -q "/dev/$VG/$name"
    mkdir -p "/mnt/$name"
    mount "/dev/$VG/$name" "/mnt/$name"
    if ! grep -q "/dev/$VG/$name " /etc/fstab; then
      echo "/dev/$VG/$name /mnt/$name ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    ok "Volume '$name' created, formatted (ext4) and mounted on /mnt/$name"
    lvs "$VG"
    df -h "/mnt/$name"
  else
    err "Could not create the volume."
  fi
}

# 4) Extend a logical volume while it is mounted
extend_lv() {
  local name size free
  echo "${BOLD}--- Extend a logical volume (online) ---${RESET}"
  if ! need lvextend; then return; fi
  lvs --noheadings -o lv_name "$VG" 2>/dev/null
  read -r -p "Volume to extend (example: lv_data): " name
  if ! is_name "$name"; then err "Invalid name."; return; fi
  if ! lv_exists "$name"; then err "Volume '$name' does not exist in $VG."; return; fi
  read -r -p "Size to ADD in MB (example: 100): " size
  if ! is_num "$size"; then err "Size must be a whole number."; return; fi
  if [ "$size" -le 0 ]; then err "Size must be greater than 0."; return; fi
  free=$(free_mb)
  if [ "$size" -gt "$free" ]; then err "Only ${free} MB free in $VG."; return; fi

  if lvextend -L "+${size}M" -r "/dev/$VG/$name"; then
    ok "Volume '$name' extended by ${size} MB (no unmount needed)."
    lvs "$VG"
  else
    err "Extend failed."
  fi
}

# 5) Snapshots: create, view, remove
do_snapshot() {
  local s lv size free snap c
  echo "${BOLD}--- Snapshot menu ---${RESET}"
  echo "  1) Create a snapshot"
  echo "  2) Mount a snapshot (read-only) and list its files"
  echo "  3) Remove a snapshot"
  read -r -p "Enter choice (1-3): " s
  if ! need lvcreate; then return; fi
  if [ "$s" = "1" ]; then
    read -r -p "Volume to snapshot [lv_data]: " lv
    lv=${lv:-lv_data}
    if ! is_name "$lv"; then err "Invalid name."; return; fi
    if ! lv_exists "$lv"; then err "Volume '$lv' does not exist."; return; fi
    read -r -p "Snapshot size in MB [100]: " size
    size=${size:-100}
    if ! is_num "$size"; then err "Size must be a whole number."; return; fi
    free=$(free_mb)
    if [ "$size" -gt "$free" ]; then err "Only ${free} MB free in $VG."; return; fi
    snap="snap_$lv"
    if lv_exists "$snap"; then err "Snapshot '$snap' already exists. Remove it first."; return; fi
    if lvcreate -s -L "${size}M" -n "$snap" "$VG/$lv"; then
      ok "Snapshot '$snap' created."
      lvs "$VG"
    else
      err "Snapshot creation failed."
    fi
  elif [ "$s" = "2" ]; then
    read -r -p "Snapshot name (example: snap_lv_data): " snap
    if [[ "$snap" != snap_* ]]; then err "Snapshot names start with snap_"; return; fi
    if ! lv_exists "$snap"; then err "Snapshot '$snap' does not exist."; return; fi
    mkdir -p /mnt/snap
    if mount -o ro "/dev/$VG/$snap" /mnt/snap; then
      ok "Snapshot mounted read-only on /mnt/snap"
      ls -l /mnt/snap
    else
      err "Could not mount the snapshot."
    fi
  elif [ "$s" = "3" ]; then
    read -r -p "Snapshot name to remove (example: snap_lv_data): " snap
    if [[ "$snap" != snap_* ]]; then err "Only names starting with snap_ can be removed here."; return; fi
    if ! lv_exists "$snap"; then err "Snapshot '$snap' does not exist."; return; fi
    read -r -p "Remove '$snap'? (y/n): " c
    if [ "$c" != "y" ]; then echo "Cancelled."; return; fi
    umount "/dev/$VG/$snap" 2>/dev/null
    if lvremove -y "$VG/$snap"; then ok "Snapshot '$snap' removed."; else err "Could not remove it."; fi
  else
    err "Invalid choice. Enter 1, 2 or 3."
  fi
}

# core backup routine (used by the menu AND by cron)
run_backup() {
  local src="$1" stamp file
  if [ ! -d "$src" ]; then err "Source folder '$src' does not exist."; return 1; fi
  if [ ! -d "$BACKUP_DIR" ]; then err "Backup folder '$BACKUP_DIR' does not exist."; return 1; fi
  if [ ! -w "$BACKUP_DIR" ]; then err "No permission to write in '$BACKUP_DIR'."; return 1; fi
  stamp=$(date +%F_%H-%M-%S)
  file="$BACKUP_DIR/$(basename "$src")_$stamp.tar.gz"
  if tar -czf "$file" -C "$(dirname "$src")" "$(basename "$src")" 2>>"$BACKUP_LOG"; then
    echo "$(date) Backup OK: $file" >> "$BACKUP_LOG"
    ok "Backup created: $file"
    ls -lh "$file"
    # keep only the last 7 days of backups
    find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete
    return 0
  else
    rm -f "$file"
    echo "$(date) Backup FAILED for $src" >> "$BACKUP_LOG"
    err "Backup failed (disk may be full). See $BACKUP_LOG"
    return 1
  fi
}

# 6) Backup (asks the user which folder)
do_backup() {
  local src
  echo "${BOLD}--- Backup ---${RESET}"
  read -r -p "Folder to back up [$DATA_DIR]: " src
  src=${src:-$DATA_DIR}
  run_backup "$src"
}

# 7) Restore a chosen backup into a chosen folder
do_restore() {
  local files f i num dest
  echo "${BOLD}--- Restore ---${RESET}"
  files=("$BACKUP_DIR"/*.tar.gz)
  if [ ! -e "${files[0]}" ]; then err "No backup files found in $BACKUP_DIR."; return; fi
  i=1
  for f in "${files[@]}"; do
    echo "  $i) $(basename "$f")"
    i=$(( i + 1 ))
  done
  read -r -p "Enter the backup number to restore: " num
  if ! is_num "$num"; then err "Please enter a number."; return; fi
  if [ "$num" -lt 1 ]; then err "Number out of range."; return; fi
  if [ "$num" -gt "${#files[@]}" ]; then err "Number out of range."; return; fi
  f="${files[$(( num - 1 ))]}"
  read -r -p "Restore into which folder [/tmp/restore_test]: " dest
  dest=${dest:-/tmp/restore_test}
  mkdir -p "$dest"
  if tar -xzf "$f" -C "$dest"; then
    ok "Restored $(basename "$f") into $dest"
    ls -l "$dest"
  else
    err "Restore failed. The backup file may be damaged."
  fi
}

# core usage check (used by the menu AND by cron)
check_usage() {
  local th="$1" mp use
  echo "=== $(date) ===" >> "$MONITOR_LOG"
  for mp in "$DATA_DIR" "$BACKUP_DIR"; do
    if [ ! -d "$mp" ]; then err "$mp not found."; continue; fi
    df --output=pcent "$mp" > "$TMP"
    use=$(sed -n 2p "$TMP")
    use=${use//[ %]/}
    if ! is_num "$use"; then err "Could not read usage of $mp"; continue; fi
    if [ "$use" -gt "$th" ]; then
      warn "$mp is ${use}% full (limit ${th}%)"
      echo "WARNING: $mp is ${use}% full" >> "$MONITOR_LOG"
    else
      ok "$mp is ${use}% full (limit ${th}%)"
      echo "OK: $mp is ${use}% full" >> "$MONITOR_LOG"
    fi
  done
}

# 8) Monitoring: warn if usage is above the threshold
do_monitor() {
  local th
  echo "${BOLD}--- Disk usage monitoring ---${RESET}"
  df -h "$DATA_DIR" "$BACKUP_DIR"
  echo
  read -r -p "Enter warning limit in percent [80]: " th
  th=${th:-80}
  if ! is_num "$th"; then err "Limit must be a whole number."; return; fi
  if [ "$th" -lt 1 ]; then err "Limit must be between 1 and 100."; return; fi
  if [ "$th" -gt 100 ]; then err "Limit must be between 1 and 100."; return; fi
  check_usage "$th"
}

# 9) Cron: view, add and remove automatic jobs
do_cron() {
  local c h m line
  echo "${BOLD}--- Automation with cron ---${RESET}"
  if ! need crontab; then return; fi
  echo "  1) Show current cron jobs"
  echo "  2) Add a daily backup job"
  echo "  3) Add a monitoring job (every N minutes)"
  echo "  4) Remove jobs created by this script"
  read -r -p "Enter choice (1-4): " c
  if [ "$c" = "1" ]; then
    crontab -l 2>/dev/null
    if [ $? -ne 0 ]; then echo "No cron jobs found."; fi
  elif [ "$c" = "2" ]; then
    read -r -p "Hour of the day for backup (0-23): " h
    if ! is_num "$h"; then err "Hour must be a number."; return; fi
    if [ "$h" -gt 23 ]; then err "Hour must be from 0 to 23."; return; fi
    line="0 $h * * * $SCRIPT_PATH --backup"
    crontab -l > "$TMP" 2>/dev/null
    if grep -q -F "$SCRIPT_PATH --backup" "$TMP"; then err "A backup job already exists. Remove it first."; return; fi
    echo "$line" >> "$TMP"
    crontab "$TMP"
    ok "Added: $line"
  elif [ "$c" = "3" ]; then
    read -r -p "Run monitoring every how many minutes (1-59): " m
    if ! is_num "$m"; then err "Minutes must be a number."; return; fi
    if [ "$m" -lt 1 ]; then err "Minutes must be from 1 to 59."; return; fi
    if [ "$m" -gt 59 ]; then err "Minutes must be from 1 to 59."; return; fi
    line="*/$m * * * * $SCRIPT_PATH --monitor"
    crontab -l > "$TMP" 2>/dev/null
    if grep -q -F "$SCRIPT_PATH --monitor" "$TMP"; then err "A monitoring job already exists. Remove it first."; return; fi
    echo "$line" >> "$TMP"
    crontab "$TMP"
    ok "Added: $line"
  elif [ "$c" = "4" ]; then
    crontab -l > "$TMP" 2>/dev/null
    grep -v -F "$SCRIPT_PATH" "$TMP" > "$TMP2"
    crontab "$TMP2"
    ok "Jobs created by this script were removed."
  else
    err "Invalid choice. Enter 1, 2, 3 or 4."
  fi
}

# 10) View the log files
view_logs() {
  local c
  echo "${BOLD}--- View logs ---${RESET}"
  echo "  1) Backup log"
  echo "  2) Monitoring log"
  read -r -p "Enter choice (1-2): " c
  if [ "$c" = "1" ]; then
    if [ -f "$BACKUP_LOG" ]; then tail -n 20 "$BACKUP_LOG"; else err "No backup log yet."; fi
  elif [ "$c" = "2" ]; then
    if [ -f "$MONITOR_LOG" ]; then tail -n 20 "$MONITOR_LOG"; else err "No monitoring log yet."; fi
  else
    err "Invalid choice. Enter 1 or 2."
  fi
}

# ---------- 5. THE MENU ----------
show_menu() {
  if [ -t 1 ]; then clear; fi
  echo "${BOLD}=================================================${RESET}"
  echo "${BOLD}      INTEGRATED LINUX STORAGE MANAGER${RESET}"
  echo "${BOLD}=================================================${RESET}"
  echo "   1) Show storage overview"
  echo "   2) Create partitions on a new disk"
  echo "   3) Create a logical volume"
  echo "   4) Extend a logical volume (online)"
  echo "   5) Snapshots (create / view / remove)"
  echo "   6) Backup now"
  echo "   7) Restore a backup"
  echo "   8) Check disk usage (warning limit)"
  echo "   9) Automation with cron"
  echo "  10) View logs"
  echo "   0) Exit"
  echo "-------------------------------------------------"
}

# ---------- 6. START-UP CHECKS ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "Error: please run this script with sudo."
  echo "Example: sudo ./storage_manager.sh"
  exit 1
fi

# non-interactive modes used by cron
case "$1" in
  --backup)  run_backup "$DATA_DIR"; exit $? ;;
  --monitor) check_usage 80; exit 0 ;;
esac

# ---------- 7. MAIN LOOP ----------
while true; do
  show_menu
  read -r -p "Enter your choice (0-10): " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    err "Please enter a number. Letters, symbols or an empty input are not allowed."
    pause
    continue
  fi
  case "$choice" in
    1)  show_overview ;;
    2)  do_partition ;;
    3)  create_lv ;;
    4)  extend_lv ;;
    5)  do_snapshot ;;
    6)  do_backup ;;
    7)  do_restore ;;
    8)  do_monitor ;;
    9)  do_cron ;;
    10) view_logs ;;
    0)  echo "Goodbye!"; exit 0 ;;
    *)  err "Invalid choice: $choice. Please choose a number from 0 to 10." ;;
  esac
  pause
done
