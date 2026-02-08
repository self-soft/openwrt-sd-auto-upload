#!/bin/sh
# OpenWrt SD watchdog for “dumb” USB SD readers that never report removal

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPTDIR/autoupload.conf"
if [ ! -f "$CONFIG" ]; then
  echo "Missing config: $CONFIG"
  exit 1
fi
. "$CONFIG"

: "${NO_MEDIA_RESET_INTERVAL:=5}"

log() { logger -t "$TAG" "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

send_rsync_stats() {
  [ -x "$TELEGRAM" ] || return 0
  [ -f "$1" ] || return 0
  stats="$(sed -n '/^Number of files/,$p' "$1" 2>/dev/null)"
  [ -n "$stats" ] || return 0
  tg_dir="$(dirname "$TELEGRAM")"
  if [ -d "$tg_dir" ]; then
    (cd "$tg_dir" 2>/dev/null && printf '%s\n' "$stats" | "$TELEGRAM" -C -) || printf '%s\n' "$stats" | "$TELEGRAM" -C -
  else
    printf '%s\n' "$stats" | "$TELEGRAM" -C -
  fi
}

block_from_dev() {
  devpath="$1"
  if have_cmd readlink; then
    devpath="$(readlink -f "$1" 2>/dev/null || echo "$1")"
  fi
  devbase="$(basename "$devpath")"
  case "$devbase" in
    *p[0-9]*)
      echo "$devbase" | sed 's/p[0-9]\+$//'
      ;;
    *[0-9])
      echo "$devbase" | sed 's/[0-9]\+$//'
      ;;
    *)
      echo "$devbase"
      ;;
  esac
}

resolve_dev() {
  new_dev=""
  if [ -n "$SD_LABEL" ]; then
    if [ -e "/dev/disk/by-label/$SD_LABEL" ] && [ -b "/dev/disk/by-label/$SD_LABEL" ]; then
      new_dev="/dev/disk/by-label/$SD_LABEL"
    elif have_cmd block; then
      dev_line="$(block info 2>/dev/null | grep -F -m1 "LABEL=\"$SD_LABEL\"")"
      [ -n "$dev_line" ] && new_dev="${dev_line%%:*}"
    fi
  elif [ -n "$SD_UUID" ]; then
    if [ -e "/dev/disk/by-uuid/$SD_UUID" ] && [ -b "/dev/disk/by-uuid/$SD_UUID" ]; then
      new_dev="/dev/disk/by-uuid/$SD_UUID"
    elif have_cmd block; then
      dev_line="$(block info 2>/dev/null | grep -F -m1 "UUID=\"$SD_UUID\"")"
      [ -n "$dev_line" ] && new_dev="${dev_line%%:*}"
    fi
  fi
  if [ -z "$new_dev" ]; then
    new_dev="$DEV"
  fi
  if [ -n "$new_dev" ] && [ "$new_dev" != "$DEV" ] && [ -e "$new_dev" ]; then
    DEV="$new_dev"
    BLOCK="$(block_from_dev "$DEV")"
    log "Detected SD device: $DEV (block $BLOCK)"
    FSCK_DONE=0
  fi
}

start_log_monitor() {
  LOGMON_PID=""
  LOGMON_FLAG=""
  have_cmd logread || return 0
  LOGMON_FLAG="/tmp/sd-watchdog-err.$$"
  : > "$LOGMON_FLAG"
  logread -f 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      *"access beyond end of device"*"$BLOCK"*|*"I/O error, dev $BLOCK"*|*"blk_update_request: I/O error, dev $BLOCK"*)
        echo 1 > "$LOGMON_FLAG"
        ;;
    esac
  done &
  LOGMON_PID=$!
}

stop_log_monitor() {
  [ -n "$LOGMON_PID" ] && kill "$LOGMON_PID" 2>/dev/null || true
  [ -n "$LOGMON_FLAG" ] && rm -f "$LOGMON_FLAG"
}

log_error_seen() {
  [ -n "$LOGMON_FLAG" ] && [ -s "$LOGMON_FLAG" ]
}

dst_host() {
  host="$DST"
  host="${host#*@}"
  host="${host%%:*}"
  echo "$host"
}

ping_host() {
  host="$(dst_host)"
  [ -n "$host" ] || return 1
  have_cmd ping || return 1
  ping -c 1 -W 1 "$host" >/dev/null 2>&1
}

notify() {
  [ -x "$TELEGRAM" ] || return 0
  [ "$#" -gt 0 ] || return 0
  if [ "$#" -eq 1 ]; then
    msg="$1"
  else
    msg="$*"
  fi
  tg_dir="$(dirname "$TELEGRAM")"
  if [ -d "$tg_dir" ]; then
    (cd "$tg_dir" 2>/dev/null && "$TELEGRAM" "$msg") || "$TELEGRAM" "$msg"
  else
    "$TELEGRAM" "$msg"
  fi
}

notify_upload_start() {
  [ -x "$TELEGRAM" ] || return 0
  size="$(du -hs "$SDPATH" 2>/dev/null)"
  if [ -z "$size" ]; then
    size="(size unavailable)"
  fi
  if cd "$SDPATH" 2>/dev/null; then
    files="$(ls -lR 2>/dev/null)"
  else
    files="(unable to list files)"
  fi
  status="upload started"
  if [ "$UPLOAD_RESUME" -eq 1 ]; then
    status="upload resumed"
  fi
  msg="$status: $UPLOAD_ID
size:
$size
files:
$files"
  notify "$msg"
}

media_present() {
  if [ -e "/sys/block/$BLOCK/size" ]; then
    size="$(cat "/sys/block/$BLOCK/size" 2>/dev/null)"
    case "$size" in
      ""|*[!0-9]*) ;;
      *)
        [ "$size" -gt 0 ] && return 0
        ;;
    esac
  fi
  [ -b "$DEV" ] && return 0
  return 1
}

is_mounted() {
  # BusyBox mountpoint may or may not exist; parse /proc/mounts instead
  grep -q " $SDPATH " /proc/mounts
}

try_mount() {
  [ -d "$SDPATH" ] || mkdir -p "$SDPATH"
  if is_mounted; then
    return 0
  fi
  # Try to mount; ignore error noise
  mount -o "$MOUNT_OPTS" "$DEV" "$SDPATH" 2>/dev/null && return 0
  return 1
}

safe_umount() {
  if is_mounted; then
    sync
    umount "$SDPATH" 2>/dev/null || true
  fi
}

reset_storage_soft() {
  # Least disruptive: remove the SCSI block device so it can be rediscovered
  if [ -e "/sys/block/$BLOCK/device/delete" ]; then
    log "Soft reset: deleting block device /sys/block/$BLOCK"
    echo 1 > "/sys/block/$BLOCK/device/delete"
    return 0
  fi
  return 1
}

reset_usb_hard() {
  # More disruptive but reliable: reset only the reader USB function (USBID)
  if [ -e "/sys/bus/usb/drivers/usb/unbind" ] && [ -e "/sys/bus/usb/drivers/usb/bind" ]; then
    log "Hard reset: unbind/bind USB device $USBID"
    echo "$USBID" > /sys/bus/usb/drivers/usb/unbind
    sleep 1
    echo "$USBID" > /sys/bus/usb/drivers/usb/bind
    return 0
  fi
  return 1
}

reset_reader() {
  # Always unmount first to avoid corruption
  safe_umount

  # Prefer soft reset; fall back to USB unbind/bind
  reset_storage_soft || reset_usb_hard
}

flag_present() {
  [ -f "$SDPATH/$FLAGFILE" ]
}

has_payload() {
  for entry in "$SDPATH"/* "$SDPATH"/.*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = "." ] && continue
    [ "$base" = ".." ] && continue
    [ "$base" = "$FLAGFILE" ] && continue
    [ "$base" = "uploadid.txt" ] && continue
    return 0
  done
  return 1
}

cleanup_sd() {
  find "$SDPATH" -mindepth 1 -maxdepth 1 ! -name "$FLAGFILE" -exec rm -rf {} \; 2>/dev/null
  sync
}

upload() {
  # Placeholder: customize to your needs.
  # Example: rsync SD content to remote host or local dir.
  #
  # REQUIREMENTS: opkg install rsync
  #
  # Example variables:
  SRC="$SDPATH/"
  RSYNC_OPTS="-a --inplace --partial --checksum --stats"

  if ! have_cmd rsync; then
    log "rsync not installed; skipping upload"
    notify "upload error: rsync not installed"
    return 1
  fi

  UPLOAD_RESUME=0
  if [ -f "$SDPATH/uploadid.txt" ]; then
    prev_id="$(cat "$SDPATH/uploadid.txt" 2>/dev/null | tr -d '\r\n')"
    case "$prev_id" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        UPLOAD_ID="$prev_id"
        UPLOAD_RESUME=1
        ;;
    esac
  fi
  if [ -z "$UPLOAD_ID" ]; then
    UPLOAD_ID="$(date +"%Y%m%d%H%M%S")"
    echo "$UPLOAD_ID" > "$SDPATH/uploadid.txt"
  fi

  DST_TARGET="$DST/$UPLOAD_ID/"
  log "Starting upload via rsync: $SRC -> $DST_TARGET"
  notify_upload_start
  start_log_monitor
  UPLOAD_ABORTED=0
  RSYNC_LOG="/tmp/rsync.$$.log"
  : > "$RSYNC_LOG"
  rsync -e "$SSH_COMMAND" $RSYNC_OPTS "$SRC" "$DST_TARGET" >"$RSYNC_LOG" 2>&1 &
  rsync_pid=$!
  while kill -0 "$rsync_pid" 2>/dev/null; do
    if log_error_seen; then
      log "Kernel I/O errors detected; stopping rsync"
      notify "upload error: media I/O error"
      UPLOAD_ABORTED=1
      kill "$rsync_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$rsync_pid" 2>/dev/null || true
      break
    fi
    if ! media_present || ! is_mounted || ! ls "$SDPATH" >/dev/null 2>&1; then
      log "Media not accessible during upload; stopping rsync"
      notify "upload error: media removed"
      UPLOAD_ABORTED=1
      kill "$rsync_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$rsync_pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$rsync_pid"
  rc=$?
  stop_log_monitor
  log "Upload finished with rc=$rc"
  if [ "$rc" -eq 0 ]; then
    send_rsync_stats "$RSYNC_LOG"
    cleanup_sd
    safe_umount
    notify "upload finished: $UPLOAD_ID"
  elif [ "$UPLOAD_ABORTED" -eq 1 ]; then
    log "Upload aborted due to media removal"
  else
    notify "upload error: $UPLOAD_ID rc=$rc"
  fi
  rm -f "$RSYNC_LOG"
  return $rc
}

main_loop() {
  log "Starting watchdog: SDPATH=$SDPATH FLAGFILE=$FLAGFILE USBID=$USBID INTERVAL=${INTERVAL}s"

  LAST_STATE=""
  FSCK_DONE=0
  PING_STATE=""
  ONLINE_NOTIFIED=0
  NO_MEDIA_COUNT=0

  while true; do
    resolve_dev

    if ping_host; then
      if [ "$PING_STATE" != "ok" ]; then
        log "Ping ok to $(dst_host)"
        PING_STATE="ok"
      fi
      if [ "$ONLINE_NOTIFIED" -eq 0 ]; then
        notify "system is online"
        ONLINE_NOTIFIED=1
      fi
    else
      if [ "$PING_STATE" != "fail" ]; then
        log "Ping failed to $(dst_host); waiting"
        PING_STATE="fail"
      fi
      sleep "$INTERVAL"
      continue
    fi

    if ! media_present; then
      if [ "$LAST_STATE" != "no-media" ]; then
        log "No SD media present; waiting"
        LAST_STATE="no-media"
        FSCK_DONE=0
        NO_MEDIA_COUNT=0
      fi
      NO_MEDIA_COUNT=$((NO_MEDIA_COUNT + 1))
      if [ "$NO_MEDIA_RESET_INTERVAL" -gt 0 ] && [ "$NO_MEDIA_COUNT" -ge "$NO_MEDIA_RESET_INTERVAL" ]; then
        log "No media for ${NO_MEDIA_RESET_INTERVAL} checks; resetting reader"
        reset_reader
        NO_MEDIA_COUNT=0
      fi
      sleep "$INTERVAL"
      continue
    fi

    if ! is_mounted; then
      if [ "$FSCK_DONE" -eq 0 ]; then
        if have_cmd fsck.exfat && [ -b "$DEV" ]; then
          log "Running fsck.exfat on $DEV"
          fsck.exfat "$DEV" --repair-auto >/dev/null 2>&1 || log "fsck.exfat returned rc=$?"
        else
          log "fsck.exfat not available; skipping"
        fi
        FSCK_DONE=1
      fi
      try_mount >/dev/null 2>&1 || true
    fi

    if ! is_mounted; then
      if [ "$LAST_STATE" != "not-mounted" ]; then
        log "Media present but not mounted; will retry"
        LAST_STATE="not-mounted"
      fi
      reset_reader
      sleep "$INTERVAL"
      continue
    fi

    if [ "$LAST_STATE" != "mounted" ]; then
      log "Media mounted at $SDPATH"
      LAST_STATE="mounted"
    fi

    if flag_present; then
      log "Flag present: $SDPATH/$FLAGFILE"
      if has_payload; then
        upload || true
      else
        log "No payload files; resetting reader to refresh contents"
        reset_reader
      fi
    else
      log "Flag missing: $SDPATH/$FLAGFILE -> resetting reader"
      reset_reader
      # Give kernel time to re-enumerate
      sleep 3
      # Try to mount again right away (optional)
      try_mount >/dev/null 2>&1 || true
    fi

    safe_umount

    sleep "$INTERVAL"
  done
}

# Locking
( set -o noclobber; echo "$$" > "$LOCK" ) 2>/dev/null || {
  echo "Already running (lock $LOCK exists)"; exit 1;
}
trap 'rm -f "$LOCK"' EXIT
trap 'rm -f "$LOCK"; exit 130' INT TERM

main_loop
