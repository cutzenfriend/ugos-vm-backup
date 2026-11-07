#!/usr/bin/env bash
#
# ugvm-backup - live VM backups for UGREEN NAS devices running UGOS.
#
# Keep this file in the folder that should hold your backups. The configuration
# and one folder per VM are stored next to it. Run it as root:
#
#   sudo bash ugvm-backup.sh          open the terminal interface
#
#   ugvm-backup.sh --run              run what is due (for cron)
#   ugvm-backup.sh --now JOB          run one job immediately
#   ugvm-backup.sh --ova BACKUP_DIR   create an OVA from an existing backup
#   ugvm-backup.sh --restore BACKUP_DIR [--yes]   put a backup back onto its VM
#   ugvm-backup.sh --check            show what the script finds on this NAS
#   ugvm-backup.sh --update [--yes]   update this script from GitHub
#   ugvm-backup.sh --version
#
# A backup never shuts a running VM down. The guest agent freezes its file systems
# for a moment, btrfs clones the disk, the VM continues, and the clone is copied.

set -u
set -o pipefail
# Since bash 5.2 "&" in a ${var//x/y} replacement means the match, which would
# break the escaping functions below.
shopt -u patsub_replacement 2>/dev/null

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LIBVIRT_DEFAULT_URI=qemu:///system
umask 077

readonly VERSION="2.1.0"
readonly CONFIG_FORMAT=2
readonly UPDATE_URL="${UGVM_UPDATE_URL:-https://raw.githubusercontent.com/cutzenfriend/ugos-vm-backup/main/ugvm-backup.sh}"
readonly MAX_CONFIG_BYTES=65536
readonly MAX_JOBS=32
readonly MAX_NAME_LENGTH=64
readonly RETRY_AFTER_SECONDS=3600
readonly CLONE_TIMEOUT_SECONDS=60
SHUTDOWN_TIMEOUT_SECONDS=${UGVM_SHUTDOWN_TIMEOUT:-300}
[[ $SHUTDOWN_TIMEOUT_SECONDS =~ ^[0-9]{1,5}$ ]] || SHUTDOWN_TIMEOUT_SECONDS=300
readonly SHUTDOWN_TIMEOUT_SECONDS
readonly LOCK_FILE=/run/ugvm-backup.lock

readonly RE_JOB_ID='^[a-z0-9][a-z0-9-]{0,31}$'
readonly RE_VM_ID='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly RE_DISK_TARGET='^[a-z][a-z0-9]{0,15}$'
readonly RE_COUNT='^(0|[1-9][0-9]{0,3})$'
readonly RE_HOURS='^[1-9][0-9]{0,3}$'
readonly RE_TIME='^([01][0-9]|2[0-3]):[0-5][0-9]$'
readonly RE_EPOCH='^[0-9]{1,12}$'
readonly RE_BYTES='^[0-9]{1,20}$'
readonly RE_VERSION='^[0-9]+\.[0-9]+\.[0-9]+$'

SCRIPT_PATH=$(realpath -- "${BASH_SOURCE[0]}")
BASE_DIR=$(dirname -- "$SCRIPT_PATH")
CONFIG_FILE="$BASE_DIR/config.ini"
LOG_FILE="$BASE_DIR/ugvm-backup.log"
STATE_DIR="$BASE_DIR/ugvm-state"

declare -A JOB=()
JOB_INDEXES=()
JOB_ERRORS=()
CONFIG_ERROR=""
VM_IDS=()
VERBOSE=0

CHILD_PID=""
FROZEN_VM=""
STAGING=""
RUNNING_JOB=""
LAST_ERROR=""
LAST_VM_DIR=""
LAST_OVA=""
TMP_FILES=()
CLONE_PATHS=()
DISK_TARGETS=()
DISK_PATHS=()
DISK_FORMATS=()
CONSISTENCY=""
COMPRESSION_TYPE=""
PROBLEMS=()
RESTORE_ACTIVE=0
RESTORE_DIR=""
RESTORE_VM=""
RESTORE_STATE=""
RESTORE_WAS_RUNNING=0
RESTORE_WARNING=""
RESTORE_MOVED=()
RESTORE_OLD=()
RESTORE_KEPT=()

# --- Logging and small helpers ------------------------------------------------

log_event() {
  local level=$1 message=${2//[[:cntrl:]]/ }
  printf '%s|%s|%s\n' "$(date +%s)" "$level" "$message" >>"$LOG_FILE" 2>/dev/null
  ((VERBOSE == 1)) && printf '%s: %s\n' "$level" "$message"
  return 0
}

fail() {
  LAST_ERROR=${1//[[:cntrl:]]/ }
  return 1
}

# Last line of a command's error output, so messages stay short.
last_line() {
  local file=$1 line
  line=$(tail -n 1 -- "$file" 2>/dev/null)
  printf '%s' "${line//[[:cntrl:]]/ }" | cut -c1-300
}

new_private_file() {
  local file
  file=$(mktemp "${TMPDIR:-/tmp}/ugvm.XXXXXXXX") || return 1
  printf '%s' "$file"
}

# Files the script creates belong to the owner of the folder, so they stay
# visible and removable with normal tools.
own_like_base() {
  chown -h --reference="$BASE_DIR" -- "$@" 2>/dev/null
  return 0
}

safe_text() {
  local value=${1//[[:cntrl:]]/ }
  value=${value//\\/}
  # whiptail would read a leading dash as an option.
  [[ $value == -* ]] && value=" $value"
  printf '%s' "$value" | cut -c1-120
}

format_size() {
  local bytes=${1:-0}
  [[ $bytes =~ $RE_BYTES ]] || bytes=0
  awk -v b="$bytes" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf(i < 4 ? "%.0f %s" : "%.1f %s", b, u[i]) }'
}

format_time() {
  [[ ${1:-} =~ $RE_EPOCH ]] && (($1 > 0)) || { printf 'never'; return 0; }
  date -d "@$1" '+%Y-%m-%d %H:%M'
}

# --- Config -------------------------------------------------------------------

add_job_error() {
  JOB_ERRORS+=("$1: $2")
}

# Invalid jobs are reported and skipped, valid jobs keep running. A broken file as
# a whole stops everything. The file is only ever read as data, never executed.
load_config() {
  JOB=()
  JOB_INDEXES=()
  JOB_ERRORS=()
  CONFIG_ERROR=""
  parse_config && return 0
  JOB=()
  JOB_INDEXES=()
  return 1
}

parse_config() {
  local line key value number=0 index=-1 version=""

  [[ -e $CONFIG_FILE || -L $CONFIG_FILE ]] || return 0
  if [[ -L $CONFIG_FILE || ! -f $CONFIG_FILE ]]; then
    CONFIG_ERROR="config.ini is not a regular file"
    return 1
  fi
  if (($(stat -c %s -- "$CONFIG_FILE") > MAX_CONFIG_BYTES)); then
    CONFIG_ERROR="config.ini is too large"
    return 1
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line == "[job]" ]]; then
      index=$((index + 1))
      if ((index >= MAX_JOBS)); then
        CONFIG_ERROR="Too many jobs (at most $MAX_JOBS)"
        return 1
      fi
      JOB_INDEXES+=("$index")
      continue
    fi
    if [[ $line != *=* ]]; then
      # The line itself is never logged: it could be from any file.
      CONFIG_ERROR="Invalid line $number in config.ini"
      return 1
    fi
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      version)
        version=$value
        ;;
      id | name | type | enabled | interval_hours | at | vms | keep_count | keep_days | compress)
        if ((index < 0)); then
          CONFIG_ERROR="Invalid line $number in config.ini"
          return 1
        fi
        JOB["$index.$key"]=$value
        ;;
      *)
        CONFIG_ERROR="Unknown key on line $number of config.ini"
        return 1
        ;;
    esac
  done <"$CONFIG_FILE"

  if [[ $version != "$CONFIG_FORMAT" ]]; then
    CONFIG_ERROR="Unsupported config version"
    return 1
  fi

  local valid=() seen=" " id
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    id=${JOB["$index.id"]:-}
    if ! [[ $id =~ $RE_JOB_ID ]]; then
      add_job_error "?" "Invalid job ID"
      continue
    fi
    if [[ $seen == *" $id "* ]]; then
      add_job_error "$id" "Duplicate job ID"
      continue
    fi
    seen+="$id "
    if validate_job "$index"; then
      valid+=("$index")
    else
      add_job_error "$id" "$LAST_ERROR"
    fi
  done
  JOB_INDEXES=("${valid[@]+"${valid[@]}"}")
  return 0
}

validate_job() {
  local index=$1 hours vm name=${JOB["$1.name"]:-}
  case "${JOB["$index.type"]:-}" in
    backup | snapshot) ;;
    *) fail "Invalid type"; return 1 ;;
  esac
  case "${JOB["$index.enabled"]:-}" in
    0 | 1) ;;
    *) fail "Invalid value for enabled"; return 1 ;;
  esac
  JOB["$index.compress"]=${JOB["$index.compress"]:-0}
  case "${JOB["$index.compress"]}" in
    0 | 1) ;;
    *) fail "Invalid value for compress"; return 1 ;;
  esac
  if ((${#name} > MAX_NAME_LENGTH)) || [[ $name =~ [[:cntrl:]] ]]; then
    fail "Invalid name"
    return 1
  fi

  hours=${JOB["$index.interval_hours"]:-}
  [[ $hours =~ $RE_HOURS ]] || { fail "Invalid interval"; return 1; }
  # Below a day the interval must divide 24 so slots line up with midnight.
  if ((hours < 24 ? 24 % hours != 0 : hours % 24 != 0)); then
    fail "Invalid interval"
    return 1
  fi
  JOB["$index.at"]=${JOB["$index.at"]:-00:00}
  [[ ${JOB["$index.at"]} =~ $RE_TIME ]] || { fail "Invalid time"; return 1; }

  [[ ${JOB["$index.keep_count"]:-} =~ $RE_COUNT ]] || { fail "Invalid backup count"; return 1; }
  [[ ${JOB["$index.keep_days"]:-} =~ $RE_COUNT ]] || { fail "Invalid retention time"; return 1; }

  local vms=${JOB["$index.vms"]:-}
  if [[ $vms != "*" ]]; then
    [[ -n $vms ]] || { fail "No VM selected"; return 1; }
    local vm_list=()
    IFS=, read -r -a vm_list <<<"$vms"
    for vm in "${vm_list[@]}"; do
      [[ $vm =~ $RE_VM_ID ]] || { fail "Invalid VM ID"; return 1; }
    done
  fi
  return 0
}

save_config() {
  local tmp index key
  tmp=$(mktemp "$BASE_DIR/.config.XXXXXXXX") || { fail "Could not write config.ini"; return 1; }
  {
    printf '# Managed by ugvm-backup.\nversion=%s\n' "$CONFIG_FORMAT"
    for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
      printf '\n[job]\n'
      for key in id name type enabled interval_hours at vms keep_count keep_days compress; do
        printf '%s=%s\n' "$key" "${JOB["$index.$key"]:-}"
      done
    done
  } >"$tmp"
  chmod 0640 -- "$tmp"
  own_like_base "$tmp"
  mv -T -f -- "$tmp" "$CONFIG_FILE" || { rm -f -- "$tmp"; fail "Could not write config.ini"; return 1; }
}

# --- Scheduling ---------------------------------------------------------------

# Prints the most recent scheduled time that is not in the future. Daily and
# longer intervals follow the local clock, so a 03:00 job stays at 03:00 across
# daylight saving changes.
latest_slot() {
  local hours=$1 at=$2 now=$3 today midnight
  today=$(date -d "@$now" +%F)
  midnight=$(date -d "$today 00:00" +%s)
  if ((hours < 24)); then
    local step=$((hours * 3600))
    printf '%s' $((midnight + (now - midnight) / step * step))
    return 0
  fi

  # 19723 is 2024-01-01, a Monday, so weekly jobs run on Mondays.
  local days=$((hours / 24)) day slot
  day=$(($(date -u -d "$today" +%s) / 86400))
  day=$((day - (day - 19723) % days))
  slot=$(local_time_on_day "$day" "$at")
  if ((slot > now)); then
    slot=$(local_time_on_day $((day - days)) "$at")
  fi
  printf '%s' "$slot"
}

local_time_on_day() {
  local day=$1 at=$2 date_text
  date_text=$(date -u -d "@$((day * 86400))" +%F)
  # A time inside the spring DST gap does not exist: use the same offset from midnight.
  date -d "$date_text $at" +%s 2>/dev/null ||
    printf '%s' $(($(date -d "$date_text 00:00" +%s) + 10#${at%%:*} * 3600 + 10#${at##*:} * 60))
}

state_file() { printf '%s/%s.%s' "$STATE_DIR" "$1" "$2"; }

state_load() {
  local file key value
  file=$(state_file "$1" "$2")
  S_FIRST=0 S_ATTEMPT=0 S_SUCCESS=0 S_DONE=0 S_RESULT="" S_ERROR=""
  [[ -f $file ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      first) [[ $value =~ $RE_EPOCH ]] && S_FIRST=$value ;;
      attempt) [[ $value =~ $RE_EPOCH ]] && S_ATTEMPT=$value ;;
      success) [[ $value =~ $RE_EPOCH ]] && S_SUCCESS=$value ;;
      done) [[ $value =~ $RE_EPOCH ]] && S_DONE=$value ;;
      result) S_RESULT=$value ;;
      error) S_ERROR=$value ;;
    esac
  done <"$file"
  return 0
}

state_save() {
  local file tmp
  mkdir -p -- "$STATE_DIR" && own_like_base "$STATE_DIR"
  file=$(state_file "$1" "$2")
  tmp=$(mktemp "$file.XXXXXX") || return 1
  printf 'first=%s\nattempt=%s\nsuccess=%s\ndone=%s\nresult=%s\nerror=%s\n' \
    "$S_FIRST" "$S_ATTEMPT" "$S_SUCCESS" "$S_DONE" "$S_RESULT" "${S_ERROR//[[:cntrl:]]/ }" >"$tmp"
  chmod 0640 -- "$tmp"
  own_like_base "$tmp"
  mv -f -- "$tmp" "$file"
}

# A new job waits for its next scheduled time instead of starting immediately.
is_due() {
  local index=$1 vm=$2 now=$3 slot reference
  if ! state_load "${JOB["$index.id"]}" "$vm"; then
    S_FIRST=$now
    state_save "${JOB["$index.id"]}" "$vm"
    return 1
  fi
  slot=$(latest_slot "${JOB["$index.interval_hours"]}" "${JOB["$index.at"]}" "$now")
  reference=$((S_DONE > S_FIRST ? S_DONE : S_FIRST))
  ((reference < slot)) && ((now - S_ATTEMPT >= RETRY_AFTER_SECONDS))
}

# --- Retention ----------------------------------------------------------------

# Reads "<epoch> <name>" lines and prints the names to delete. Both limits apply,
# 0 disables one, and the newest entry always survives: a limit must never be
# able to delete the last remaining backup of a VM.
select_expired() {
  local keep_count=$1 keep_days=$2 now=$3 position=0 epoch name
  sort -rn | while read -r epoch name; do
    position=$((position + 1))
    ((position == 1)) && continue
    if ((keep_count > 0 && position > keep_count)) ||
      ((keep_days > 0 && now - epoch > keep_days * 86400)); then
      printf '%s\n' "$name"
    fi
  done
}

prune_backups() {
  local index=$1 base=$2 now=$3 job dir name stamp epoch
  job=${JOB["$index.id"]}
  local pattern="^backup-$job-([0-9]{8})-([0-9]{6})\$"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    log_event info "Retention: deleting ${base##*/}/$name"
    rm -rf --one-file-system -- "${base:?}/$name" ||
      log_event error "Could not delete ${base##*/}/$name"
  done < <(
    for dir in "$base"/*; do
      name=${dir##*/}
      [[ $name =~ $pattern ]] || continue
      [[ -d $dir && ! -L $dir && -f $dir/manifest.txt && ! -L $dir/manifest.txt ]] || continue
      stamp=${BASH_REMATCH[2]}
      epoch=$(date -d "${BASH_REMATCH[1]} ${stamp:0:2}:${stamp:2:2}:${stamp:4:2}" +%s 2>/dev/null) || continue
      printf '%s %s\n' "$epoch" "$name"
    done | select_expired "${JOB["$index.keep_count"]}" "${JOB["$index.keep_days"]}" "$now"
  )
}

# Prints "<epoch> <name>" for snapshots created by this job. The marker in the
# description keeps manually created UGOS snapshots out of retention entirely.
list_job_snapshots() {
  local vm=$1 job=$2 name xml epoch names=()
  mapfile -t names < <(virsh snapshot-list --domain "$vm" --name 2>/dev/null)
  for name in "${names[@]+"${names[@]}"}"; do
    [[ -n $name ]] || continue
    xml=$(virsh snapshot-dumpxml --domain "$vm" --snapshotname "$name" 2>/dev/null) || continue
    grep -qF "<description>ugvm-backup:job=$job</description>" <<<"$xml" || continue
    epoch=$(sed -n 's/.*<creationTime>\([0-9]*\)<\/creationTime>.*/\1/p' <<<"$xml" | head -n 1)
    [[ $epoch =~ $RE_EPOCH ]] || continue
    printf '%s %s\n' "$epoch" "$name"
  done
}

prune_snapshots() {
  local index=$1 vm=$2 now=$3 name
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    log_event info "Retention: deleting snapshot $name"
    virsh snapshot-delete --domain "$vm" --snapshotname "$name" >/dev/null 2>&1 ||
      log_event error "Could not delete snapshot $name"
  done < <(
    list_job_snapshots "$vm" "${JOB["$index.id"]}" |
      select_expired "${JOB["$index.keep_count"]}" "${JOB["$index.keep_days"]}" "$now"
  )
}

# --- Running long commands ----------------------------------------------------

# Runs a command in the background so a signal can stop it. The command's last
# error line ends up in LAST_ERROR.
run_long() {
  local err code
  err=$(new_private_file) || return 1
  TMP_FILES+=("$err")
  "$@" >/dev/null 2>"$err" &
  CHILD_PID=$!
  wait "$CHILD_PID"
  code=$?
  CHILD_PID=""
  ((code == 0)) || LAST_ERROR=$(last_line "$err")
  return "$code"
}

# Copies run with the lowest CPU and disk priority, so other services on the NAS
# keep their speed. A backup then takes longer when the NAS is busy.
heavy() {
  local prefix=()
  command -v nice >/dev/null 2>&1 && prefix+=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && prefix+=(ionice -c 2 -n 7)
  "${prefix[@]}" "$@"
}

# zstd is faster than zlib at a similar ratio, but needs qemu-img 5.1 or newer.
detect_compression() {
  [[ -n $COMPRESSION_TYPE ]] && return 0
  local probe
  probe=$(new_private_file) || { COMPRESSION_TYPE=zlib; return 0; }
  TMP_FILES+=("$probe")
  if qemu-img create -q -f qcow2 -o compression_type=zstd "$probe" 1M >/dev/null 2>&1; then
    COMPRESSION_TYPE=zstd
  else
    COMPRESSION_TYPE=zlib
  fi
}

# --- VM information -----------------------------------------------------------

vm_state() { virsh domstate --domain "$1" 2>/dev/null | head -n 1; }

vm_title() {
  local title
  title=$(virsh desc --domain "$1" --title 2>/dev/null | head -n 1)
  [[ $title == "No title"* ]] && title=""
  printf '%s' "${title//[[:cntrl:]]/ }"
}

load_vm_list() {
  local vm names=()
  VM_IDS=()
  mapfile -t names < <(virsh list --all --name 2>/dev/null)
  for vm in "${names[@]+"${names[@]}"}"; do
    [[ $vm =~ $RE_VM_ID ]] && VM_IDS+=("$vm")
  done
}

vm_known() {
  [[ " ${VM_IDS[*]+"${VM_IDS[*]}"} " == *" $1 "* ]]
}

# Readable and stable: the title for people, the start of the ID for uniqueness.
vm_folder_name() {
  local vm=$1 title=$2 safe
  safe=$(printf '%s' "$title" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//' | cut -c1-48)
  if [[ -n $safe ]]; then
    printf '%s-%s' "$safe" "${vm:0:8}"
  else
    printf '%s' "$vm"
  fi
}

# The disk format always comes from the domain definition. qemu-img must never
# probe it: a guest could put a qcow2 header on a raw disk, name a host file as
# backing file and have root read it into the backup.
disk_format() {
  awk -v wanted="dev='$2'" '
    /<disk / { in_disk = 1; format = ""; found = 0 }
    in_disk && /<driver / && match($0, /type=.[a-z0-9]+/) { format = substr($0, RSTART + 6, RLENGTH - 6) }
    in_disk && /<target / && index($0, wanted) { found = 1 }
    /<\/disk>/ { if (found) { print format; exit } in_disk = 0 }
  ' <<<"$1"
}

load_disks() {
  local vm=$1 xml type device target source format
  DISK_TARGETS=()
  DISK_PATHS=()
  DISK_FORMATS=()
  xml=$(virsh dumpxml --inactive --domain "$vm" 2>/dev/null) || { fail "Can't read the VM definition"; return 1; }
  while read -r type device target source; do
    [[ $device == disk ]] || continue
    if [[ $source == - || -z $source ]]; then
      continue
    fi
    [[ $type == file ]] || { fail "Disk $target: type $type is not supported"; return 1; }
    [[ $target =~ $RE_DISK_TARGET ]] || { fail "Unexpected disk name"; return 1; }
    [[ $source == /* && ! $source =~ [[:cntrl:]] ]] || { fail "Unexpected disk path"; return 1; }
    [[ -f $source && ! -L $source ]] || { fail "Disk $target not found"; return 1; }
    format=$(disk_format "$xml" "$target")
    case "$format" in
      qcow2 | raw) ;;
      *) fail "Disk $target: format ${format:-unknown} is not supported"; return 1 ;;
    esac
    DISK_TARGETS+=("$target")
    DISK_PATHS+=("$source")
    DISK_FORMATS+=("$format")
  done < <(virsh domblklist --domain "$vm" --details 2>/dev/null | tail -n +3)
  ((${#DISK_TARGETS[@]} > 0)) || { fail "VM has no disk that can be backed up"; return 1; }
  return 0
}

# --- Capturing disks ----------------------------------------------------------

thaw_vm() {
  [[ -n $FROZEN_VM ]] || return 0
  local vm=$FROZEN_VM
  for _ in 1 2 3; do
    if virsh domfsthaw --domain "$vm" >/dev/null 2>&1; then
      FROZEN_VM=""
      return 0
    fi
    /bin/sleep 1
  done
  FROZEN_VM=""
  log_event error "Could not thaw the file systems of VM $vm"
  fail "Could not thaw the file systems of the VM"
}

# The clone must be on the same file system as the disk, so it goes on that volume.
prepare_clone_paths() {
  local vm=$1 index mount dir
  CLONE_PATHS=()
  for index in "${!DISK_TARGETS[@]}"; do
    mount=$(findmnt -no TARGET -T "${DISK_PATHS[$index]}" 2>/dev/null | head -n 1)
    [[ $mount == /* ]] || { fail "Can't find the volume of disk ${DISK_TARGETS[$index]}"; return 1; }
    dir="${mount%/}/.ugvm-clone"
    if [[ -L $dir ]] || { [[ ! -d $dir ]] && ! mkdir -m 0700 -- "$dir"; }; then
      fail "Can't create the clone folder on $mount"
      return 1
    fi
    CLONE_PATHS+=("$dir/$vm-${DISK_TARGETS[$index]}.${DISK_FORMATS[$index]}")
    rm -f -- "${CLONE_PATHS[$index]}"
  done
}

# Freeze, clone every disk, thaw. Everything else happens after the VM continues.
clone_running_vm() {
  local vm=$1 index started elapsed err
  prepare_clone_paths "$vm" || return 1
  err=$(new_private_file) || err=/dev/null
  [[ $err != /dev/null ]] && TMP_FILES+=("$err")

  if ! virsh domfsfreeze --domain "$vm" >/dev/null 2>"$err"; then
    fail "Could not freeze the VM. Is qemu-guest-agent running inside it? $(last_line "$err")"
    return 1
  fi
  FROZEN_VM=$vm
  started=$(date +%s%N)
  for index in "${!DISK_TARGETS[@]}"; do
    if ! timeout "$CLONE_TIMEOUT_SECONDS" cp --reflink=always -- "${DISK_PATHS[$index]}" "${CLONE_PATHS[$index]}" 2>"$err"; then
      thaw_vm
      fail "Could not clone disk ${DISK_TARGETS[$index]}. The disk must be on btrfs. $(last_line "$err")"
      return 1
    fi
  done
  thaw_vm || return 1
  elapsed=$((($(date +%s%N) - started) / 1000000))
  log_event info "VM $vm was frozen for $elapsed ms"
  CONSISTENCY="filesystem"
}

discard_clones() {
  local path
  for path in "${CLONE_PATHS[@]+"${CLONE_PATHS[@]}"}"; do
    rm -f -- "$path"
    rmdir -- "${path%/*}" 2>/dev/null
  done
  CLONE_PATHS=()
  return 0
}

copy_disks() {
  local dest=$1 compress=${2:-0} index source options=()
  if [[ $compress == 1 ]]; then
    detect_compression
    options=(-c)
    [[ $COMPRESSION_TYPE == zstd ]] && options+=(-o compression_type=zstd)
  fi
  for index in "${!DISK_TARGETS[@]}"; do
    source=${DISK_PATHS[$index]}
    [[ -n ${CLONE_PATHS[$index]:-} ]] && source=${CLONE_PATHS[$index]}
    log_verbose "Copying disk ${DISK_TARGETS[$index]}"
    run_long heavy qemu-img convert -f "${DISK_FORMATS[$index]}" -O qcow2 "${options[@]}" \
      -- "$source" "$dest/${DISK_TARGETS[$index]}.qcow2" || {
      fail "Could not copy disk ${DISK_TARGETS[$index]}: $LAST_ERROR"
      return 1
    }
    log_verbose "Checking disk ${DISK_TARGETS[$index]}"
    run_long heavy qemu-img check -f qcow2 -- "$dest/${DISK_TARGETS[$index]}.qcow2" || {
      fail "Check of disk ${DISK_TARGETS[$index]} failed: $LAST_ERROR"
      return 1
    }
  done
}

log_verbose() {
  ((VERBOSE == 1)) && printf '%s\n' "$1"
  return 0
}

copy_vm_metadata() {
  local vm=$1 dest=$2 xml nvram uuid
  xml=$(virsh dumpxml --inactive --domain "$vm" 2>/dev/null) || { fail "Can't read the VM definition"; return 1; }
  printf '%s\n' "$xml" >"$dest/domain.xml"

  nvram=$(sed -n 's/.*<nvram[^>]*>\([^<]*\)<\/nvram>.*/\1/p' <<<"$xml" | head -n 1)
  if [[ $nvram == /* && -f $nvram && ! -L $nvram ]]; then
    cp --no-dereference -- "$nvram" "$dest/nvram.fd" || { fail "Could not copy the UEFI variables"; return 1; }
  fi

  uuid=$(virsh domuuid --domain "$vm" 2>/dev/null | head -n 1)
  if [[ $uuid =~ ^[0-9a-f-]{36}$ && -d /var/lib/libvirt/swtpm/$uuid ]]; then
    tar -C /var/lib/libvirt/swtpm -czf "$dest/tpm-state.tar.gz" -- "$uuid" ||
      { fail "Could not copy the TPM state"; return 1; }
  fi
}

check_free_space() {
  local dest_parent=$1 needed=0 path used available
  for path in "${DISK_PATHS[@]}"; do
    used=$(du -sB1 -- "$path" 2>/dev/null | cut -f1)
    [[ $used =~ $RE_BYTES ]] && needed=$((needed + used))
  done
  needed=$((needed + needed / 10))
  available=$(df --output=avail -B1 -- "$dest_parent" 2>/dev/null | tail -n 1 | tr -d ' ')
  [[ $available =~ $RE_BYTES ]] || { fail "Could not determine free space"; return 1; }
  if ((available < needed)); then
    fail "Not enough space: $((available / 1073741824)) GiB free, about $((needed / 1073741824)) GiB needed"
    return 1
  fi
}

# A symlink here would redirect root's writes, so anything unexpected is refused.
prepare_vm_dir() {
  local dir=$1
  if [[ -L $dir || (-e $dir && ! -d $dir) ]]; then
    fail "This VM's folder is not a regular folder"
    return 1
  fi
  mkdir -p -- "$dir" || { fail "Could not create the VM's folder"; return 1; }
  [[ $(realpath -e -- "$dir") == "$dir" ]] || { fail "The VM's folder points somewhere else"; return 1; }
  own_like_base "$dir"
  chmod 0750 -- "$dir"
}

# --- One backup of one VM -----------------------------------------------------

backup_vm() {
  local index=$1 vm=$2 now=$3 job state title vm_dir name
  job=${JOB["$index.id"]}

  load_disks "$vm" || return 1
  state=$(vm_state "$vm")
  title=$(vm_title "$vm")
  vm_dir="$BASE_DIR/$(vm_folder_name "$vm" "$title")"

  prepare_vm_dir "$vm_dir" || return 1
  check_free_space "$BASE_DIR" || return 1

  # A crash can leave a partial folder behind. This run holds the lock, so any
  # partial folder of this job is left over from an earlier run.
  local leftover
  for leftover in "$vm_dir/.partial-backup-$job-"*; do
    [[ -d $leftover && ! -L $leftover ]] && rm -rf --one-file-system -- "$leftover"
  done

  name="backup-$job-$(date -d "@$now" +%Y%m%d-%H%M%S)"
  STAGING="$vm_dir/.partial-$name"
  mkdir -m 0700 -- "$STAGING" || { STAGING=""; fail "Could not create the working folder"; return 1; }

  CLONE_PATHS=()
  case "$state" in
    "shut off")
      CONSISTENCY="offline"
      ;;
    running)
      log_verbose "Freezing and cloning $vm"
      clone_running_vm "$vm" || return 1
      ;;
    *)
      fail "VM is in state ${state:-unknown}"
      return 1
      ;;
  esac

  copy_disks "$STAGING" "${JOB["$index.compress"]:-0}" || return 1
  discard_clones
  copy_vm_metadata "$vm" "$STAGING" || return 1

  local size
  size=$(du -sB1 -- "$STAGING" | cut -f1)
  {
    printf 'format=2\nid=%s\njob=%s\ntype=backup\nvm=%s\ntitle=%s\n' "$name" "$job" "$vm" "$title"
    printf 'created=%s\nconsistency=%s\nsize=%s\ncompressed=%s\nscript_version=%s\n' \
      "$now" "$CONSISTENCY" "$size" "${JOB["$index.compress"]:-0}" "$VERSION"
  } >"$STAGING/manifest.txt"

  find -P "$STAGING" -type d -exec chmod 0750 {} +
  find -P "$STAGING" -type f -exec chmod 0640 {} +
  chown -hR --reference="$BASE_DIR" -- "$STAGING" 2>/dev/null

  # The final name only exists for complete, verified backups.
  mv -T -- "$STAGING" "$vm_dir/$name" || { fail "Could not finish the backup"; return 1; }
  STAGING=""
  log_event info "Backup finished: ${vm_dir##*/}/$name ($CONSISTENCY)"
  LAST_VM_DIR=$vm_dir
  return 0
}

take_snapshot() {
  local index=$1 vm=$2 now=$3 err
  err=$(new_private_file) || err=/dev/null
  [[ $err != /dev/null ]] && TMP_FILES+=("$err")
  # Same naming scheme as UGOS. The description marks it as ours for retention.
  if ! virsh snapshot-create-as --domain "$vm" --name "${vm}_$now" \
    --description "ugvm-backup:job=${JOB["$index.id"]}" --atomic >/dev/null 2>"$err"; then
    fail "Snapshot failed: $(last_line "$err")"
    return 1
  fi
  log_event info "Snapshot created: ${vm}_$now"
}

run_vm() {
  local index=$1 vm=$2 now=$3 job code=0 attempt_now
  job=${JOB["$index.id"]}
  state_load "$job" "$vm"
  attempt_now=$(date +%s)
  S_ATTEMPT=$attempt_now
  [[ $S_FIRST == 0 ]] && S_FIRST=$now
  S_RESULT="running"
  S_ERROR=""
  state_save "$job" "$vm"

  RUNNING_JOB="$job, VM $vm"
  LAST_ERROR=""
  LAST_VM_DIR=""
  log_verbose "Job $job: $vm"

  if ! vm_known "$vm"; then
    fail "VM not found"
    code=1
  elif [[ ${JOB["$index.type"]} == snapshot ]]; then
    take_snapshot "$index" "$vm" "$attempt_now" || code=1
  else
    backup_vm "$index" "$vm" "$attempt_now" || code=1
  fi

  thaw_vm
  discard_clones
  discard_staging

  state_load "$job" "$vm"
  S_ATTEMPT=$attempt_now
  if ((code == 0)); then
    S_SUCCESS=$(date +%s)
    S_DONE=$S_SUCCESS
    S_RESULT="ok"
    # Retention runs only after a success, so a failing job can never eat through
    # the backups that are still good.
    if [[ ${JOB["$index.type"]} == snapshot ]]; then
      prune_snapshots "$index" "$vm" "$(date +%s)"
    else
      prune_backups "$index" "$LAST_VM_DIR" "$(date +%s)"
    fi
  else
    S_RESULT="error"
    S_ERROR=$LAST_ERROR
    log_event error "Job $job, VM $vm: $LAST_ERROR"
  fi
  state_save "$job" "$vm"
  RUNNING_JOB=""
  return "$code"
}

discard_staging() {
  if [[ -n $STAGING ]]; then
    [[ -d $STAGING && ! -L $STAGING ]] && rm -rf --one-file-system -- "$STAGING"
    STAGING=""
  fi
  return 0
}

job_vm_list() {
  local vms=${JOB["$1.vms"]}
  if [[ $vms == "*" ]]; then
    printf '%s\n' "${VM_IDS[@]+"${VM_IDS[@]}"}"
  else
    tr ',' '\n' <<<"$vms"
  fi
}

run_job_now() {
  local index=$1 vm vms=() failed=0
  mapfile -t vms < <(job_vm_list "$index")
  for vm in "${vms[@]+"${vms[@]}"}"; do
    [[ $vm =~ $RE_VM_ID ]] || continue
    run_vm "$index" "$vm" "$(date +%s)" || failed=1
  done
  return "$failed"
}

# --- OVA ----------------------------------------------------------------------

xml_escape() {
  local value=$1
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\'/&apos;}
  value=${value//\"/&quot;}
  printf '%s' "$value"
}

# Everything comes from the backup itself, so this also works for a VM that no
# longer exists. targets: disk names; each $dest/<name>.vmdk must exist.
write_ovf() {
  local title=$1 dest=$2 is_uefi=$3 cpus=$4 memory_kib=$5 nics=$6
  shift 6
  local disk_refs="" disk_defs="" items="" index=0 instance=4 target file size capacity

  for target in "$@"; do
    file="$target.vmdk"
    size=$(stat -c %s -- "$dest/$file") || return 1
    capacity=$(qemu-img info -f vmdk --output=json -- "$dest/$file" |
      sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -n 1)
    [[ $capacity =~ ^[0-9]+$ ]] || { fail "Can't read the size of $file"; return 1; }
    disk_refs+="    <File ovf:id=\"file-$target\" ovf:href=\"$file\" ovf:size=\"$size\"/>"$'\n'
    disk_defs+="    <Disk ovf:diskId=\"disk-$target\" ovf:fileRef=\"file-$target\" ovf:capacity=\"$capacity\" ovf:format=\"http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized\"/>"$'\n'
    items+="      <Item><rasd:AddressOnParent>$index</rasd:AddressOnParent><rasd:ElementName>$target</rasd:ElementName><rasd:HostResource>ovf:/disk/disk-$target</rasd:HostResource><rasd:InstanceID>$instance</rasd:InstanceID><rasd:Parent>3</rasd:Parent><rasd:ResourceType>17</rasd:ResourceType></Item>"$'\n'
    index=$((index + 1))
    instance=$((instance + 1))
  done

  local nic=0 network_section=""
  if ((nics > 0)); then
    network_section='  <NetworkSection><Info>Networks</Info><Network ovf:name="VM Network"><Description>VM Network</Description></Network></NetworkSection>'
  fi
  while ((nic < nics)); do
    items+="      <Item><rasd:AddressOnParent>$nic</rasd:AddressOnParent><rasd:AutomaticAllocation>true</rasd:AutomaticAllocation><rasd:Connection>VM Network</rasd:Connection><rasd:ElementName>nic$nic</rasd:ElementName><rasd:InstanceID>$instance</rasd:InstanceID><rasd:ResourceSubType>E1000</rasd:ResourceSubType><rasd:ResourceType>10</rasd:ResourceType></Item>"$'\n'
    nic=$((nic + 1))
    instance=$((instance + 1))
  done

  local firmware=""
  [[ $is_uefi == true ]] && firmware='      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>'
  local safe_title
  safe_title=$(xml_escape "$title")

  cat >"$dest/vm.ovf" <<OVF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">
  <References>
${disk_refs%$'\n'}
  </References>
  <DiskSection>
    <Info>Virtual disks</Info>
${disk_defs%$'\n'}
  </DiskSection>
$network_section
  <VirtualSystem ovf:id="vm">
    <Info>Virtual machine</Info>
    <Name>$safe_title</Name>
    <OperatingSystemSection ovf:id="0"><Info>Guest operating system</Info></OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware</Info>
      <System><vssd:ElementName>Virtual Hardware Family</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemType>vmx-13</vssd:VirtualSystemType></System>
      <Item><rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits><rasd:ElementName>$cpus vCPU</rasd:ElementName><rasd:InstanceID>1</rasd:InstanceID><rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>$cpus</rasd:VirtualQuantity></Item>
      <Item><rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits><rasd:ElementName>RAM</rasd:ElementName><rasd:InstanceID>2</rasd:InstanceID><rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>$((memory_kib / 1024))</rasd:VirtualQuantity></Item>
      <Item><rasd:Address>0</rasd:Address><rasd:ElementName>SCSI controller</rasd:ElementName><rasd:InstanceID>3</rasd:InstanceID><rasd:ResourceSubType>lsilogic</rasd:ResourceSubType><rasd:ResourceType>6</rasd:ResourceType></Item>
${items%$'\n'}
$firmware
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
OVF
}

# Reads the title from a manifest. The folder can be changed by normal users, so
# nothing from it is executed and everything is checked or escaped.
manifest_value() {
  local file=$1 wanted=$2 key value
  [[ -f $file && ! -L $file ]] || return 0
  while IFS='=' read -r key value; do
    if [[ $key == "$wanted" ]]; then
      printf '%s' "${value//[[:cntrl:]]/ }"
      return 0
    fi
  done < <(head -c 4096 -- "$file")
}

build_ova() {
  local dir=$1 xml cpus memory_kib nics is_uefi=false title file target targets=() needed=0 available
  [[ -d $dir && ! -L $dir && -f $dir/manifest.txt && -f $dir/domain.xml ]] || { fail "This is not a complete backup"; return 1; }
  dir=$(realpath -e -- "$dir")
  xml="$dir/domain.xml"

  cpus=$(sed -n 's/.*<vcpu[^>]*>\([0-9]*\)<\/vcpu>.*/\1/p' "$xml" | head -n 1)
  memory_kib=$(sed -n "s/.*<memory[^>]*>\([0-9]*\)<\/memory>.*/\1/p" "$xml" | head -n 1)
  [[ $cpus =~ ^[0-9]{1,5}$ && $memory_kib =~ ^[0-9]{1,15}$ ]] || { fail "Can't read CPU and RAM from the backup"; return 1; }
  nics=$(grep -c '<interface ' "$xml")
  grep -qE '<nvram|<loader' "$xml" && is_uefi=true
  title=$(manifest_value "$dir/manifest.txt" title)

  for file in "$dir"/*.qcow2; do
    [[ -f $file && ! -L $file ]] || continue
    target=${file##*/}
    target=${target%.qcow2}
    [[ $target =~ $RE_DISK_TARGET ]] || { fail "Unexpected disk name in the backup"; return 1; }
    targets+=("$target")
    needed=$((needed + $(stat -c %s -- "$file")))
  done
  ((${#targets[@]} > 0)) || { fail "The backup has no disks"; return 1; }

  available=$(df --output=avail -B1 -- "$dir" 2>/dev/null | tail -n 1 | tr -d ' ')
  if [[ $available =~ $RE_BYTES ]] && ((available < needed)); then
    fail "Not enough space: $((available / 1073741824)) GiB free, up to $((needed / 1073741824)) GiB needed"
    return 1
  fi

  STAGING="$dir/.partial-ova"
  [[ -L $STAGING ]] && { STAGING=""; fail "Unexpected link in the backup"; return 1; }
  rm -rf --one-file-system -- "$STAGING"
  mkdir -m 0700 -- "$STAGING" || { STAGING=""; fail "Could not create the working folder"; return 1; }

  for target in "${targets[@]}"; do
    log_verbose "Converting disk $target"
    run_long heavy qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized \
      -- "$dir/$target.qcow2" "$STAGING/$target.vmdk" || {
      fail "OVA conversion failed: $LAST_ERROR"
      return 1
    }
  done

  write_ovf "${title:-${dir##*/}}" "$STAGING" "$is_uefi" "$cpus" "$memory_kib" "$nics" "${targets[@]}" || return 1

  local files=()
  for target in "${targets[@]}"; do
    files+=("$target.vmdk")
  done
  (
    cd -- "$STAGING" || exit 1
    : >vm.mf
    for file in vm.ovf "${files[@]}"; do
      printf 'SHA256(%s)= %s\n' "$file" "$(sha256sum -- "$file" | cut -d' ' -f1)" >>vm.mf
    done
  ) || { fail "Could not create checksums"; return 1; }

  # The OVF specification requires the descriptor to be the first file.
  run_long heavy tar --format=ustar -C "$STAGING" -cf "$STAGING/vm.ova" -- vm.ovf vm.mf "${files[@]}" || {
    fail "Could not create the OVA archive: $LAST_ERROR"
    return 1
  }
  chmod 0640 -- "$STAGING/vm.ova"
  chown --reference="$BASE_DIR" -- "$STAGING/vm.ova" 2>/dev/null
  mv -T -f -- "$STAGING/vm.ova" "$dir/vm.ova" || { fail "Could not finish the OVA"; return 1; }
  discard_staging
  log_event info "OVA created: ${dir##*/}"
  LAST_OVA="$dir/vm.ova"
}

# --- Readiness ----------------------------------------------------------------

# Fills PROBLEMS with what prevents a live backup of this VM. A powered-off VM can
# still be backed up without btrfs or a guest agent.
vm_problems() {
  local vm=$1 index fs attrs
  PROBLEMS=()
  if ! load_disks "$vm"; then
    PROBLEMS+=("$LAST_ERROR")
    return 0
  fi
  for index in "${!DISK_TARGETS[@]}"; do
    fs=$(findmnt -no FSTYPE -T "${DISK_PATHS[$index]}" 2>/dev/null | head -n 1)
    if [[ $fs != btrfs ]]; then
      PROBLEMS+=("Disk ${DISK_TARGETS[$index]} is on ${fs:-an unknown file system}. Live backups need btrfs.")
    fi
    attrs=$(lsattr -- "${DISK_PATHS[$index]}" 2>/dev/null | cut -d' ' -f1)
    if [[ $attrs == *C* ]]; then
      PROBLEMS+=("Disk ${DISK_TARGETS[$index]} has nodatacow set and can't be cloned.")
    fi
  done
  if [[ $(vm_state "$vm") == running ]] && ! virsh domfsinfo --domain "$vm" >/dev/null 2>&1; then
    PROBLEMS+=("The guest agent doesn't answer. Is qemu-guest-agent running inside the VM?")
  fi
  return 0
}

# --- Storage ------------------------------------------------------------------

storage_text() {
  local free folder size total=0 need=0 lines="" dir created newest newest_size
  free=$(df --output=avail -B1 -- "$BASE_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')
  [[ $free =~ $RE_BYTES ]] || free=0
  for folder in "$BASE_DIR"/*/; do
    folder=${folder%/}
    [[ -L $folder ]] && continue
    compgen -G "$folder/backup-*" >/dev/null || continue
    size=$(du -sB1 -- "$folder" 2>/dev/null | cut -f1)
    [[ $size =~ $RE_BYTES ]] || size=0
    total=$((total + size))
    newest=0
    newest_size=0
    for dir in "$folder"/backup-*; do
      [[ -d $dir && ! -L $dir ]] || continue
      created=$(manifest_value "$dir/manifest.txt" created)
      [[ $created =~ $RE_EPOCH ]] || continue
      if ((created > newest)); then
        newest=$created
        newest_size=$(manifest_value "$dir/manifest.txt" size)
        [[ $newest_size =~ $RE_BYTES ]] || newest_size=0
      fi
    done
    need=$((need + newest_size))
    lines+="  $(safe_text "${folder##*/}"): $(format_size "$size")"$'\n'
  done

  printf 'Storage\n  Free: %s\n  Used by backups: %s\n%s' "$(format_size "$free")" "$(format_size "$total")" "$lines"
  if ((need > 0)); then
    if ((free < need + need / 10)); then
      printf '  ! Not enough free space for the next backup of every VM (about %s).\n' "$(format_size "$need")"
    else
      printf '  Room for about %s more backups of every VM\n' "$((free / need))"
    fi
  fi
}

# --- Restore ------------------------------------------------------------------

# Checks everything that can be checked while the VM keeps running, so a problem
# never leaves a VM shut down for nothing.
restore_prepare() {
  local dir=$1 vm file target index found count compressed size available
  RESTORE_DIR=""
  RESTORE_VM=""
  [[ -d $dir && ! -L $dir && -f $dir/manifest.txt ]] || { fail "This is not a complete backup"; return 1; }
  dir=$(realpath -e -- "$dir")
  vm=$(manifest_value "$dir/manifest.txt" vm)
  [[ $vm =~ $RE_VM_ID ]] || { fail "The backup doesn't name its VM"; return 1; }
  load_vm_list
  if ! vm_known "$vm"; then
    fail "This VM no longer exists. Create an OVA from the backup and import it as a new VM."
    return 1
  fi
  load_disks "$vm" || return 1

  count=$(virsh snapshot-list --domain "$vm" --name 2>/dev/null | grep -c .)
  if ((count > 0)); then
    fail "This VM has $count snapshot(s), which restoring would break. Delete them in UGOS first, or create an OVA from the backup and import it as a new VM."
    return 1
  fi

  for file in "$dir"/*.qcow2; do
    [[ -f $file && ! -L $file ]] || continue
    target=${file##*/}
    target=${target%.qcow2}
    found=0
    for index in "${!DISK_TARGETS[@]}"; do
      [[ ${DISK_TARGETS[$index]} == "$target" ]] && found=1
    done
    ((found == 1)) || { fail "The backup's disks don't match the VM's current disks"; return 1; }
  done

  compressed=$(manifest_value "$dir/manifest.txt" compressed)
  for index in "${!DISK_TARGETS[@]}"; do
    file="$dir/${DISK_TARGETS[$index]}.qcow2"
    [[ -f $file && ! -L $file ]] || { fail "The backup's disks don't match the VM's current disks"; return 1; }
    log_verbose "Checking the backup of disk ${DISK_TARGETS[$index]}"
    run_long heavy qemu-img check -f qcow2 -- "$file" || {
      fail "The backup of disk ${DISK_TARGETS[$index]} is damaged: $LAST_ERROR"
      return 1
    }
    if [[ $compressed == 1 ]]; then
      size=$(qemu-img info -f qcow2 --output=json -- "$file" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -n 1)
    else
      size=$(du -sB1 -- "$file" | cut -f1)
    fi
    [[ $size =~ $RE_BYTES ]] || size=0
    available=$(df --output=avail -B1 -- "${DISK_PATHS[$index]%/*}" 2>/dev/null | tail -n 1 | tr -d ' ')
    if [[ $available =~ $RE_BYTES ]] && ((available < size + size / 10)); then
      fail "Not enough space next to disk ${DISK_TARGETS[$index]}: $((available / 1073741824)) GiB free, about $((size / 1073741824)) GiB needed"
      return 1
    fi
  done

  RESTORE_STATE=$(vm_state "$vm")
  case "$RESTORE_STATE" in
    running | "shut off") ;;
    *) fail "VM is in state ${RESTORE_STATE:-unknown}"; return 1 ;;
  esac
  RESTORE_DIR=$dir
  RESTORE_VM=$vm
}

# Puts the previous disks back. Used when a restore fails or is interrupted.
restore_rollback() {
  local index
  for ((index = ${#RESTORE_MOVED[@]} - 1; index >= 0; index--)); do
    rm -f -- "${RESTORE_MOVED[$index]}"
    mv -f -- "${RESTORE_OLD[$index]}" "${RESTORE_MOVED[$index]}" ||
      log_event error "Could not move ${RESTORE_OLD[$index]} back"
  done
  RESTORE_MOVED=()
  RESTORE_OLD=()
  RESTORE_ACTIVE=0
  if ((RESTORE_WAS_RUNNING == 1)); then
    virsh start --domain "$RESTORE_VM" >/dev/null 2>&1 || log_event error "Could not start VM $RESTORE_VM again"
  fi
  return 0
}

# The previous disks stay next to the new ones until the user deletes them.
restore_run() {
  local vm=$RESTORE_VM dir=$RESTORE_DIR stamp index path old waited=0 error xml nvram
  stamp=$(date +%Y%m%d-%H%M%S)
  RESTORE_WAS_RUNNING=0
  RESTORE_WARNING=""
  RESTORE_MOVED=()
  RESTORE_OLD=()
  RESTORE_KEPT=()

  if [[ $RESTORE_STATE == running ]]; then
    log_verbose "Shutting down the VM"
    virsh shutdown --domain "$vm" >/dev/null 2>&1 || { fail "Could not shut down the VM. Nothing was changed."; return 1; }
    while [[ $(vm_state "$vm") != "shut off" ]]; do
      if ((waited >= SHUTDOWN_TIMEOUT_SECONDS)); then
        fail "The VM did not shut down within $((SHUTDOWN_TIMEOUT_SECONDS / 60)) minutes. Nothing was changed. If it shuts down later, start it again in UGOS."
        return 1
      fi
      /bin/sleep 2
      waited=$((waited + 2))
    done
    RESTORE_WAS_RUNNING=1
  fi

  RESTORE_ACTIVE=1
  for index in "${!DISK_TARGETS[@]}"; do
    path=${DISK_PATHS[$index]}
    old="$path.before-restore-$stamp"
    if ! mv -- "$path" "$old"; then
      restore_rollback
      fail "Could not move disk ${DISK_TARGETS[$index]} aside. Nothing was changed."
      return 1
    fi
    RESTORE_MOVED+=("$path")
    RESTORE_OLD+=("$old")
    log_verbose "Restoring disk ${DISK_TARGETS[$index]}"
    if ! run_long heavy qemu-img convert -f qcow2 -O "${DISK_FORMATS[$index]}" -- "$dir/${DISK_TARGETS[$index]}.qcow2" "$path"; then
      error=$LAST_ERROR
      restore_rollback
      fail "Could not restore disk ${DISK_TARGETS[$index]}: $error. The previous disks are back in place."
      return 1
    fi
    chown --reference="$old" -- "$path" 2>/dev/null
    chmod --reference="$old" -- "$path" 2>/dev/null
  done
  RESTORE_KEPT=("${RESTORE_OLD[@]}")

  xml=$(virsh dumpxml --inactive --domain "$vm" 2>/dev/null)
  nvram=$(sed -n 's/.*<nvram[^>]*>\([^<]*\)<\/nvram>.*/\1/p' <<<"$xml" | head -n 1)
  if [[ -f $dir/nvram.fd && $nvram == /* && -f $nvram && ! -L $nvram ]]; then
    old="$nvram.before-restore-$stamp"
    if cp -p -- "$nvram" "$old" && cp -- "$dir/nvram.fd" "$nvram.new" &&
      chown --reference="$old" -- "$nvram.new" && chmod --reference="$old" -- "$nvram.new" &&
      mv -f -- "$nvram.new" "$nvram"; then
      RESTORE_KEPT+=("$old")
    else
      rm -f -- "$nvram.new"
      RESTORE_WARNING="The UEFI variables could not be restored, the VM keeps its current ones."
    fi
  fi
  RESTORE_MOVED=()
  RESTORE_OLD=()
  RESTORE_ACTIVE=0

  if ((RESTORE_WAS_RUNNING == 1)); then
    log_verbose "Starting the VM"
    virsh start --domain "$vm" >/dev/null 2>&1 ||
      RESTORE_WARNING+="${RESTORE_WARNING:+ }The VM could not be started. Start it in UGOS."
  fi
  log_event info "Restored VM $vm from ${dir##*/}"
  return 0
}

cli_restore() {
  local dir=$1 assume_yes=$2 answer path
  acquire_lock || { printf 'Another backup is running.\n' >&2; return 1; }
  VERBOSE=1
  restore_prepare "$dir" || { printf "Can't restore: %s\n" "$LAST_ERROR" >&2; return 1; }
  printf 'Restore VM %s from %s.\n' "$(vm_label "$RESTORE_VM")" "${RESTORE_DIR##*/}"
  [[ $RESTORE_STATE == running ]] && printf 'The VM is running. It will be shut down, restored and started again.\n'
  printf 'Everything that changed inside the VM since this backup will be lost.\n'
  if ((assume_yes == 0)); then
    [[ -t 0 ]] || { printf 'Run again with --yes to restore.\n'; return 1; }
    read -r -p 'Restore now? [y/N] ' answer
    [[ $answer == [yY]* ]] || { printf 'Nothing changed.\n'; return 0; }
  fi
  restore_run || { printf 'Restore failed: %s\n' "$LAST_ERROR" >&2; return 1; }
  printf 'Restored. The previous files are kept until you delete them:\n'
  for path in "${RESTORE_KEPT[@]}"; do
    printf '  %s\n' "$path"
  done
  [[ -n $RESTORE_WARNING ]] && printf '%s\n' "$RESTORE_WARNING"
  return 0
}

# --- Backups on disk ----------------------------------------------------------

# Prints "<epoch>|<size>|<job>|<title>|<path>", newest first.
list_backups() {
  local dir name job created size title vm_folder
  for dir in "$BASE_DIR"/*/backup-*; do
    name=${dir##*/}
    [[ $name =~ ^backup-([a-z0-9][a-z0-9-]{0,31})-[0-9]{8}-[0-9]{6}$ ]] || continue
    job=${BASH_REMATCH[1]}
    [[ -d $dir && ! -L $dir && -f $dir/manifest.txt ]] || continue
    created=$(manifest_value "$dir/manifest.txt" created)
    size=$(manifest_value "$dir/manifest.txt" size)
    title=$(manifest_value "$dir/manifest.txt" title)
    [[ $created =~ $RE_EPOCH ]] || created=0
    [[ $size =~ $RE_BYTES ]] || size=0
    vm_folder=${dir%/*}
    title=$(safe_text "${title:-${vm_folder##*/}}")
    printf '%s|%s|%s|%s|%s\n' "$created" "$size" "$job" "${title//|/ }" "$dir"
  done | sort -t'|' -k1,1rn
}

last_backup_of_vm() {
  local vm=$1 dir created newest=0
  for dir in "$BASE_DIR"/*/backup-*; do
    [[ -d $dir && ! -L $dir ]] || continue
    [[ $(manifest_value "$dir/manifest.txt" vm) == "$vm" ]] || continue
    created=$(manifest_value "$dir/manifest.txt" created)
    [[ $created =~ $RE_EPOCH ]] && ((created > newest)) && newest=$created
  done
  printf '%s' "$newest"
}

# --- Update -------------------------------------------------------------------

version_is_newer() {
  local candidate=$1 current=$2
  [[ $candidate != "$current" && $(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1) == "$candidate" ]]
}

# Downloads next to the script, so the final step is an atomic rename. Sets
# UPDATE_FILE and UPDATE_VERSION when a newer valid version is available.
fetch_update() {
  local err
  UPDATE_FILE=""
  UPDATE_VERSION=""
  UPDATE_FILE=$(mktemp "$BASE_DIR/.ugvm-update.XXXXXXXX") || { fail "Could not create a temporary file"; return 1; }
  err=$(new_private_file) || err=/dev/null
  [[ $err != /dev/null ]] && TMP_FILES+=("$err")
  TMP_FILES+=("$UPDATE_FILE")
  if ! curl -fsSL --proto '=https,file' --max-time 120 --max-filesize 5000000 -o "$UPDATE_FILE" -- "$UPDATE_URL" 2>"$err"; then
    fail "Download failed: $(last_line "$err")"
    return 1
  fi
  [[ $(head -c 2 -- "$UPDATE_FILE") == "#!" ]] || { fail "The download is not a script"; return 1; }
  bash -n -- "$UPDATE_FILE" 2>/dev/null || { fail "The download has syntax errors"; return 1; }
  UPDATE_VERSION=$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$UPDATE_FILE" | head -n 1)
  [[ $UPDATE_VERSION =~ $RE_VERSION ]] || { fail "The download has no valid version"; return 1; }
}

install_update() {
  chmod --reference="$SCRIPT_PATH" -- "$UPDATE_FILE" 2>/dev/null || chmod 0755 -- "$UPDATE_FILE"
  chown --reference="$SCRIPT_PATH" -- "$UPDATE_FILE" 2>/dev/null
  cp -p -- "$SCRIPT_PATH" "$SCRIPT_PATH.previous" || { fail "Could not keep the previous version"; return 1; }
  mv -T -f -- "$UPDATE_FILE" "$SCRIPT_PATH" || { fail "Could not replace the script"; return 1; }
  log_event info "Updated from $VERSION to $UPDATE_VERSION"
}

cli_update() {
  local assume_yes=$1 answer
  fetch_update || { printf 'Update failed: %s\n' "$LAST_ERROR" >&2; return 1; }
  if ! version_is_newer "$UPDATE_VERSION" "$VERSION"; then
    printf 'Version %s is up to date (GitHub has %s).\n' "$VERSION" "$UPDATE_VERSION"
    return 0
  fi
  printf 'Update available: %s -> %s\n' "$VERSION" "$UPDATE_VERSION"
  if ((assume_yes == 0)); then
    [[ -t 0 ]] || { printf 'Run again with --yes to install.\n'; return 0; }
    read -r -p 'Install it? [y/N] ' answer
    [[ $answer == [yY]* ]] || { printf 'Nothing changed.\n'; return 0; }
  fi
  acquire_lock || { printf 'A backup is running. Try again later.\n' >&2; return 1; }
  install_update || { printf 'Update failed: %s\n' "$LAST_ERROR" >&2; return 1; }
  printf 'Updated to %s.\n' "$UPDATE_VERSION"
}

# --- Cron ---------------------------------------------------------------------

cron_line() {
  local path
  path=$(printf '%q' "$SCRIPT_PATH")
  # "%" starts a new line in a crontab unless it is escaped.
  printf '*/10 * * * * /bin/bash %s --run >/dev/null 2>&1' "${path//%/\\%}"
}

cron_installed() {
  local table
  table=$(crontab -l 2>/dev/null) || return 1
  grep -qF -- "$(cron_line)" <<<"$table"
}

cron_install() {
  cron_installed && return 0
  { crontab -l 2>/dev/null; cron_line; printf '\n'; } | crontab -
}

cron_remove() {
  local line
  line=$(cron_line)
  { crontab -l 2>/dev/null | grep -vF -- "$line" || true; } | crontab -
}

# --- Terminal interface -------------------------------------------------------

# Prints the choice on stdout. whiptail draws on stdout and answers on stderr.
wt() {
  whiptail --title "VM Backup" --backtitle "ugvm-backup $VERSION" "$@" 3>&1 1>&2 2>&3
}

screen_size() {
  local size
  size=$(stty size 2>/dev/null) || size="24 80"
  SCREEN_ROWS=${size%% *}
  SCREEN_COLS=${size##* }
  [[ $SCREEN_ROWS =~ ^[0-9]+$ && $SCREEN_COLS =~ ^[0-9]+$ ]] || { SCREEN_ROWS=24; SCREEN_COLS=80; }
  ((SCREEN_ROWS < 16)) && SCREEN_ROWS=16
  ((SCREEN_COLS > 110)) && SCREEN_COLS=110
  ((SCREEN_COLS < 60)) && SCREEN_COLS=60
  return 0
}

tui_message() { wt --msgbox "$1" 0 0 >/dev/null; }

# Text that fits gets a normal window that closes with Enter. In a scrolling window
# Enter does nothing, because the focus is on the text, so that one says what to do.
tui_page() {
  local width lines
  screen_size
  width=$((SCREEN_COLS - 4))
  lines=$(awk -v w="$((width - 4))" '{ n += 1 + int(length($0) / w) } END { print n + 0 }' <<<"$1")
  if ((lines + 7 <= SCREEN_ROWS - 2)); then
    wt --msgbox "$1" "$((lines + 7))" "$width" >/dev/null
  else
    wt --scrolltext --msgbox "Arrow keys scroll. Press Tab, then Enter to close."$'\n\n'"$1" "$((SCREEN_ROWS - 2))" "$width" >/dev/null
  fi
}

interval_name() {
  case "$1" in
    1) printf 'Every hour' ;;
    24) printf 'Daily' ;;
    48) printf 'Every 2 days' ;;
    72) printf 'Every 3 days' ;;
    168) printf 'Weekly (Mondays)' ;;
    336) printf 'Every 2 weeks (Mondays)' ;;
    720) printf 'Every 30 days' ;;
    *) printf 'Every %s hours' "$1" ;;
  esac
}

job_summary() {
  local index=$1 text retention hours=${JOB["$1.interval_hours"]}
  text=$(interval_name "$hours")
  ((hours >= 24)) && text+=" at ${JOB["$index.at"]}"
  retention="${JOB["$index.keep_count"]} kept"
  [[ ${JOB["$index.keep_count"]} == 0 ]] && retention="no count limit"
  [[ ${JOB["$index.keep_days"]} != 0 ]] && retention+=", ${JOB["$index.keep_days"]} days"
  [[ ${JOB["$index.compress"]:-0} == 1 ]] && retention+=", compressed"
  [[ ${JOB["$index.enabled"]} == 0 ]] && text="Paused, $text"
  printf '%s: %s, %s' "${JOB["$index.type"]}" "$text" "$retention"
}

vm_label() {
  local title
  title=$(vm_title "$1")
  safe_text "${title:-$1}"
}

tui_status() {
  local text vm index job latest result_lines=""
  load_vm_list
  text="Folder: $BASE_DIR"$'\n'
  if cron_installed; then
    text+="Schedule: active (root cron job)"$'\n'
  else
    text+="Schedule: NOT ACTIVE. Turn it on under cron."$'\n'
  fi
  [[ -n $CONFIG_ERROR ]] && text+="Config error: $CONFIG_ERROR"$'\n'
  local entry
  for entry in "${JOB_ERRORS[@]+"${JOB_ERRORS[@]}"}"; do
    text+="Invalid job $(safe_text "$entry")"$'\n'
  done

  text+=$'\n'"Virtual machines"$'\n'
  for vm in "${VM_IDS[@]+"${VM_IDS[@]}"}"; do
    latest=$(last_backup_of_vm "$vm")
    text+="  $(vm_label "$vm") ($(vm_state "$vm")), last backup: $(format_time "$latest")"$'\n'
    vm_problems "$vm"
    local problem
    for problem in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do
      text+="    ! $(safe_text "$problem")"$'\n'
    done
  done
  ((${#VM_IDS[@]} > 0)) || text+="  None found"$'\n'
  text+=$'\n'"$(storage_text)"$'\n'

  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    job=${JOB["$index.id"]}
    while IFS= read -r vm; do
      [[ $vm =~ $RE_VM_ID ]] || continue
      state_load "$job" "$vm" || continue
      [[ $S_RESULT == error ]] && result_lines+="  $(safe_text "${JOB["$index.name"]:-$job}"), $(vm_label "$vm"): $(safe_text "$S_ERROR")"$'\n'
    done < <(job_vm_list "$index")
  done
  [[ -n $result_lines ]] && text+=$'\n'"Problems"$'\n'"$result_lines"

  if [[ -f $LOG_FILE ]]; then
    text+=$'\n'"Recent events"$'\n'
    local time level message
    while IFS='|' read -r time level message; do
      text+="  $(format_time "$time") $level: $(safe_text "$message")"$'\n'
    done < <(tail -n 8 -- "$LOG_FILE")
  fi
  tui_page "$text"
}

# Edits a copy of a job and only commits it once it is complete and valid.
tui_edit_job() {
  local index=$1 is_new=0 value k d="draft"
  for k in id name type enabled interval_hours at vms keep_count keep_days compress; do
    JOB["$d.$k"]=${JOB["$index.$k"]:-}
  done
  if [[ -z ${JOB["$d.id"]} ]]; then
    is_new=1
    JOB["$d.id"]="j-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    JOB["$d.type"]=backup
    JOB["$d.enabled"]=1
    JOB["$d.interval_hours"]=24
    JOB["$d.at"]=03:00
    JOB["$d.vms"]="*"
    JOB["$d.keep_count"]=7
    JOB["$d.keep_days"]=30
    JOB["$d.compress"]=0
  fi

  value=$(wt --inputbox "Job name" 0 60 "${JOB["$d.name"]}") || return 1
  JOB["$d.name"]=$value

  value=$(wt --default-item "${JOB["$d.type"]}" --menu "What should this job create?" 0 0 0 \
    backup "Full copy of the disks in this folder" \
    snapshot "Snapshot in the VM disk, doesn't protect against drive failure") || return 1
  JOB["$d.type"]=$value

  tui_select_vms "$d" || return 1

  value=$(wt --default-item "${JOB["$d.interval_hours"]}" --menu "How often?" 0 0 0 \
    1 "$(interval_name 1)" 2 "$(interval_name 2)" 3 "$(interval_name 3)" 4 "$(interval_name 4)" \
    6 "$(interval_name 6)" 8 "$(interval_name 8)" 12 "$(interval_name 12)" 24 "$(interval_name 24)" \
    48 "$(interval_name 48)" 72 "$(interval_name 72)" 168 "$(interval_name 168)" \
    336 "$(interval_name 336)" 720 "$(interval_name 720)") || return 1
  JOB["$d.interval_hours"]=$value

  if ((value >= 24)); then
    value=$(wt --inputbox "Start time (HH:MM)" 0 40 "${JOB["$d.at"]}") || return 1
    JOB["$d.at"]=$value
  fi

  value=$(wt --inputbox "Keep at most this many backups (0 = no limit). The newest is never deleted." 0 60 "${JOB["$d.keep_count"]}") || return 1
  JOB["$d.keep_count"]=$value
  value=$(wt --inputbox "Keep backups for at most this many days (0 = no limit). The newest is never deleted." 0 60 "${JOB["$d.keep_days"]}") || return 1
  JOB["$d.keep_days"]=$value

  if [[ ${JOB["$d.type"]} == backup ]]; then
    local compress_default=(--defaultno)
    [[ ${JOB["$d.compress"]} == 1 ]] && compress_default=()
    if wt "${compress_default[@]}" --yesno "Compress the backups? This saves space, but copying takes longer." 0 0 >/dev/null; then
      JOB["$d.compress"]=1
    else
      JOB["$d.compress"]=0
    fi
  else
    JOB["$d.compress"]=0
  fi

  if wt --yesno "Run this job on its schedule?" 0 0 >/dev/null; then
    JOB["$d.enabled"]=1
  else
    JOB["$d.enabled"]=0
  fi

  if ! validate_job "$d"; then
    tui_message "Not saved: $LAST_ERROR"
    return 1
  fi
  if [[ ${JOB["$d.type"]} == backup ]] && ! tui_confirm_readiness "$d"; then
    return 1
  fi

  for k in id name type enabled interval_hours at vms keep_count keep_days compress; do
    JOB["$index.$k"]=${JOB["$d.$k"]}
  done
  ((is_new == 1)) && JOB_INDEXES+=("$index")
  tui_save_jobs
}

# Warns before saving a job for VMs that can't be backed up while they run.
tui_confirm_readiness() {
  local d=$1 vm vms=() text="" problem
  load_vm_list
  mapfile -t vms < <(job_vm_list "$d")
  for vm in "${vms[@]+"${vms[@]}"}"; do
    [[ $vm =~ $RE_VM_ID ]] && vm_known "$vm" || continue
    vm_problems "$vm"
    for problem in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do
      text+="$(vm_label "$vm"): $(safe_text "$problem")"$'\n'
    done
  done
  [[ -z $text ]] && return 0
  wt --yes-button "Save" --no-button "Back" --yesno "These VMs can't be backed up while they run:\n\n$text\nPowered-off VMs are still backed up. Save the job anyway?" 0 0 >/dev/null
}

tui_select_vms() {
  local d=$1 vm value selected=() items=() on all="OFF"
  [[ ${JOB["$d.vms"]} == "*" ]] && all="ON"
  items+=(ALL "All VMs, including future ones" "$all")
  load_vm_list
  for vm in "${VM_IDS[@]+"${VM_IDS[@]}"}"; do
    on="OFF"
    [[ ",${JOB["$d.vms"]}," == *",$vm,"* ]] && on="ON"
    items+=("$vm" "$(vm_label "$vm")" "$on")
  done
  value=$(wt --separate-output --checklist "Which VMs? Space selects." 0 0 0 "${items[@]}") || return 1
  mapfile -t selected <<<"$value"
  if [[ " ${selected[*]} " == *" ALL "* ]]; then
    JOB["$d.vms"]="*"
  else
    JOB["$d.vms"]=$(IFS=,; printf '%s' "${selected[*]}")
  fi
}

tui_save_jobs() {
  if ((${#JOB_ERRORS[@]} > 0)); then
    wt --defaultno --yesno "config.ini contains ${#JOB_ERRORS[@]} invalid job(s). Saving removes them. Continue?" 0 0 >/dev/null || return 1
  fi
  if ! save_config; then
    tui_message "$LAST_ERROR"
    return 1
  fi
  JOB_ERRORS=()
  return 0
}

tui_jobs() {
  local choice items index next
  while :; do
    items=()
    for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
      items+=("$index" "$(safe_text "${JOB["$index.name"]:-${JOB["$index.id"]}}") ($(job_summary "$index"))")
    done
    items+=(new "Create a job")
    choice=$(wt --menu "Jobs" 0 0 0 "${items[@]}") || return 0
    if [[ $choice == new ]]; then
      if ((${#JOB_INDEXES[@]} >= MAX_JOBS)); then
        tui_message "You have reached the limit of $MAX_JOBS jobs."
        continue
      fi
      next=0
      for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
        ((index >= next)) && next=$((index + 1))
      done
      tui_edit_job "$next" && tui_message "Job saved. It first runs at its next scheduled time."
    else
      tui_job_actions "$choice"
    fi
  done
}

tui_job_actions() {
  local index=$1 choice label
  label=$(safe_text "${JOB["$index.name"]:-${JOB["$index.id"]}}")
  choice=$(wt --menu "$label" 0 0 0 \
    run "Back up now" edit "Edit" delete "Delete") || return 0
  case "$choice" in
    run) tui_run_job "$index" ;;
    edit) tui_edit_job "$index" ;;
    delete)
      if wt --defaultno --yesno "Delete the job \"$label\"? Its existing backups are kept." 0 0 >/dev/null; then
        local kept=() i
        for i in "${JOB_INDEXES[@]}"; do
          [[ $i == "$index" ]] || kept+=("$i")
        done
        JOB_INDEXES=("${kept[@]+"${kept[@]}"}")
        tui_save_jobs
      fi
      ;;
  esac
}

tui_run_job() {
  local index=$1 code
  if ! acquire_lock; then
    tui_message "Another backup is running. Try again when it has finished."
    return 0
  fi
  clear 2>/dev/null
  printf 'Running job: %s\n\n' "$(safe_text "${JOB["$index.name"]:-${JOB["$index.id"]}}")"
  load_vm_list
  VERBOSE=1
  run_job_now "$index"
  code=$?
  VERBOSE=0
  release_lock
  if ((code == 0)); then
    printf '\nFinished.\n'
  else
    printf '\nFinished with errors.\n'
  fi
  read -r -p 'Press Enter to continue. ' _
}

tui_backups() {
  local lines=() line choice items i created size job title path
  while :; do
    mapfile -t lines < <(list_backups)
    if ((${#lines[@]} == 0)); then
      tui_message "There are no backups in this folder yet."
      return 0
    fi
    items=()
    for i in "${!lines[@]}"; do
      IFS='|' read -r created size job title path <<<"${lines[$i]}"
      items+=("$i" "$(format_time "$created")  $(format_size "$size")  $title")
    done
    choice=$(wt --menu "Backups, newest first" 0 0 0 "${items[@]}") || return 0
    IFS='|' read -r created size job title path <<<"${lines[$choice]}"
    tui_backup_actions "$path" "$title" "$created" "$size"
  done
}

tui_backup_actions() {
  local path=$1 title=$2 created=$3 size=$4 choice
  choice=$(wt --menu "$title, $(format_time "$created")" 0 0 0 \
    details "Show details" restore "Put this backup back onto the VM" \
    ova "Create OVA for importing" delete "Delete this backup") || return 0
  case "$choice" in
    details)
      local consistency
      consistency=$(manifest_value "$path/manifest.txt" consistency)
      tui_page "VM: $title
Created: $(format_time "$created")
Size: $(format_size "$size")
State when copied: $(safe_text "$consistency")
Path: $path

Files:
$(ls -1 -- "$path")"
      ;;
    ova) tui_create_ova "$path" ;;
    restore) tui_restore "$path" "$title" "$created" ;;
    delete)
      if wt --defaultno --yesno "Permanently delete this backup?\n\n$title, $(format_time "$created")" 0 0 >/dev/null; then
        if ! acquire_lock; then
          tui_message "A backup is running. Try again when it has finished."
          return 0
        fi
        rm -rf --one-file-system -- "$path" && log_event info "Backup deleted: ${path##*/}"
        release_lock
      fi
      ;;
  esac
}

tui_restore() {
  local path=$1 title=$2 created=$3 question kept_text="" file
  if ! acquire_lock; then
    tui_message "A backup is running. Try again when it has finished."
    return 0
  fi
  clear 2>/dev/null
  printf 'Checking the backup...\n'
  VERBOSE=1
  if ! restore_prepare "$path"; then
    VERBOSE=0
    release_lock
    tui_message "Can't restore: $LAST_ERROR"
    return 0
  fi
  VERBOSE=0
  question="Restore $title to the backup from $(format_time "$created")?\n\n"
  if [[ $RESTORE_STATE == running ]]; then
    question+="The VM is running. It will be shut down, restored and started again.\n\n"
  else
    question+="The VM is off and stays off.\n\n"
  fi
  question+="Everything that changed inside the VM since this backup will be lost. Its current disks are kept next to them until you delete them."
  if ! wt --defaultno --yes-button "Restore" --no-button "Cancel" --yesno "$question" 0 0 >/dev/null; then
    release_lock
    return 0
  fi
  clear 2>/dev/null
  VERBOSE=1
  if restore_run; then
    VERBOSE=0
    release_lock
    for file in "${RESTORE_KEPT[@]}"; do
      kept_text+="$file\n"
    done
    tui_message "Restored.${RESTORE_WARNING:+\n\n$RESTORE_WARNING}\n\nThe previous files are kept here. Delete them once the VM works:\n\n$kept_text"
  else
    VERBOSE=0
    release_lock
    tui_message "Restore failed: $LAST_ERROR"
  fi
}

tui_create_ova() {
  local path=$1 question="Create an OVA from this backup? This can take a while, the VMs keep running."
  [[ -f $path/vm.ova ]] && question="This backup already has an OVA. Create it again?"
  wt --yesno "$question" 0 0 >/dev/null || return 0
  if ! acquire_lock; then
    tui_message "A backup is running. Try again when it has finished."
    return 0
  fi
  clear 2>/dev/null
  printf 'Creating OVA...\n'
  VERBOSE=1
  if build_ova "$path"; then
    VERBOSE=0
    release_lock
    tui_message "OVA created:\n\n$LAST_OVA\n\nImport it in the Virtual Machine app."
  else
    VERBOSE=0
    discard_staging
    release_lock
    tui_message "OVA failed: $LAST_ERROR"
  fi
}

tui_cron() {
  if cron_installed; then
    wt --defaultno --yes-button "Remove" --no-button "Keep" --yesno "The schedule is active. This line runs in root's crontab every 10 minutes, and the script only acts when a job is due:\n\n$(cron_line)\n\nRemove it? Jobs then stop running on their own." 0 0 >/dev/null || return 0
    cron_remove && tui_message "Schedule removed."
  else
    wt --yesno "Jobs only run on their own with this line in root's crontab. It runs every 10 minutes, and the script only acts when a job is due:\n\n$(cron_line)\n\nAdd it now?" 0 0 >/dev/null || return 0
    if cron_install && cron_installed; then
      tui_message "Schedule active."
    else
      tui_message "Could not change root's crontab. Add the line with: sudo crontab -e"
    fi
  fi
}

# Without the cron line, jobs silently never run, so this is checked on every start.
tui_offer_schedule() {
  cron_installed && return 0
  wt --yesno "The schedule is not active, so jobs don't run on their own.\n\nAdd this line to root's crontab now? It runs every 10 minutes, and the script only acts when a job is due:\n\n$(cron_line)" 0 0 >/dev/null || return 0
  if cron_install && cron_installed; then
    tui_message "Schedule active."
  else
    tui_message "Could not change root's crontab. Add the line with: sudo crontab -e"
  fi
}

tui_update() {
  if ! fetch_update; then
    tui_message "Update check failed: $LAST_ERROR"
    return 0
  fi
  if ! version_is_newer "$UPDATE_VERSION" "$VERSION"; then
    tui_message "Version $VERSION is up to date."
    return 0
  fi
  wt --yesno "Version $UPDATE_VERSION is available, you have $VERSION.\n\nInstall it from GitHub now? The current version is kept as $(basename -- "$SCRIPT_PATH").previous." 0 0 >/dev/null || return 0
  if ! acquire_lock; then
    tui_message "A backup is running. Try again when it has finished."
    return 0
  fi
  if install_update; then
    release_lock
    tui_message "Updated to $UPDATE_VERSION. Start the script again to use it."
    exit 0
  fi
  release_lock
  tui_message "Update failed: $LAST_ERROR"
}

tui_main() {
  if ! command -v whiptail >/dev/null 2>&1; then
    printf 'whiptail is not installed. Use --run, --now, --ova, --check or --update instead.\n' >&2
    return 2
  fi
  # A terminal the NAS doesn't know would break the display.
  tput longname >/dev/null 2>&1 || export TERM=xterm
  locale -a 2>/dev/null | grep -qix 'C.utf-\?8' && export LC_ALL=C.UTF-8

  load_config
  [[ -n $CONFIG_ERROR ]] && tui_message "config.ini can't be used: $CONFIG_ERROR\n\nFix or delete the file to change jobs here."

  tui_offer_schedule

  local choice schedule cron_action
  while :; do
    if cron_installed; then
      schedule="Schedule: active"
      cron_action="Turn the schedule off"
    else
      schedule="Schedule: NOT active, jobs don't run on their own"
      cron_action="Turn the schedule on"
    fi
    choice=$(wt --menu "$schedule\n\nWhat do you want to do?" 0 0 0 \
      status "Overview and problems" \
      jobs "Create and change backup jobs" \
      backups "Show backups, create OVAs" \
      cron "$cron_action" \
      update "Check for a new version" \
      exit "Leave") || break
    case "$choice" in
      status) tui_status ;;
      jobs)
        if [[ -n $CONFIG_ERROR ]]; then
          tui_message "config.ini can't be used: $CONFIG_ERROR"
        else
          tui_jobs
        fi
        ;;
      backups) tui_backups ;;
      cron) tui_cron ;;
      update) tui_update ;;
      exit) break ;;
    esac
  done
  clear 2>/dev/null
  return 0
}

# --- Startup ------------------------------------------------------------------

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9
}

release_lock() {
  flock -u 9 2>/dev/null
  return 0
}

trim_log() {
  if [[ -f $LOG_FILE ]] && (($(stat -c %s -- "$LOG_FILE") > 262144)); then
    local trimmed
    trimmed=$(mktemp "$LOG_FILE.XXXXXX") &&
      tail -n 1000 -- "$LOG_FILE" >"$trimmed" &&
      chmod 0640 -- "$trimmed" &&
      own_like_base "$trimmed" &&
      mv -f -- "$trimmed" "$LOG_FILE"
  fi
  if [[ ! -e $LOG_FILE ]]; then
    : >"$LOG_FILE" 2>/dev/null && chmod 0640 -- "$LOG_FILE" && own_like_base "$LOG_FILE"
  fi
  return 0
}

on_exit() {
  local code=$?
  trap - EXIT TERM INT HUP
  [[ -n $CHILD_PID ]] && kill "$CHILD_PID" 2>/dev/null
  thaw_vm
  ((RESTORE_ACTIVE == 1)) && restore_rollback
  discard_clones
  discard_staging
  rm -f -- "${TMP_FILES[@]+"${TMP_FILES[@]}"}"
  [[ -n $RUNNING_JOB ]] && log_event error "Run was interrupted (job $RUNNING_JOB)"
  exit "$code"
}

run_check() {
  local vm index problem
  printf 'ugvm-backup %s\nfolder: %s\n' "$VERSION" "$BASE_DIR"
  printf 'qemu-img: %s\n' "$(command -v qemu-img >/dev/null && echo yes || echo NO)"
  printf 'whiptail: %s\n' "$(command -v whiptail >/dev/null && echo yes || echo NO)"
  printf 'curl: %s\n' "$(command -v curl >/dev/null && echo yes || echo NO)"
  printf 'schedule: %s\n' "$(cron_installed && echo active || echo 'not active')"
  load_vm_list
  printf 'VMs: %s\n' "${#VM_IDS[@]}"
  for vm in "${VM_IDS[@]+"${VM_IDS[@]}"}"; do
    printf '\n%s (%s, %s)\n' "$(vm_label "$vm")" "$vm" "$(vm_state "$vm")"
    vm_problems "$vm"
    for index in "${!DISK_TARGETS[@]}"; do
      printf '  %s: %s, %s, %s\n' "${DISK_TARGETS[$index]}" "${DISK_FORMATS[$index]}" \
        "$(findmnt -no FSTYPE -T "${DISK_PATHS[$index]}" 2>/dev/null | head -n 1)" "${DISK_PATHS[$index]}"
    done
    for problem in "${PROBLEMS[@]+"${PROBLEMS[@]}"}"; do
      printf '  problem: %s\n' "$problem"
    done
    ((${#PROBLEMS[@]} == 0)) && printf '  ready for live backups\n'
  done
  printf '\n%s\n\n' "$(storage_text)"
  load_config
  if [[ -n $CONFIG_ERROR ]]; then
    printf 'config: ERROR: %s\n' "$CONFIG_ERROR"
    return 1
  fi
  printf 'valid jobs: %s\n' "${#JOB_INDEXES[@]}"
  local entry
  for entry in "${JOB_ERRORS[@]+"${JOB_ERRORS[@]}"}"; do
    printf 'invalid job %s\n' "$(safe_text "$entry")"
  done
  return 0
}

run_scheduled() {
  acquire_lock || return 0
  load_config || { log_event error "$CONFIG_ERROR"; return 1; }
  load_vm_list
  local index vm job vms=() now
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    job=${JOB["$index.id"]}
    [[ ${JOB["$index.enabled"]} == 1 ]] || continue
    mapfile -t vms < <(job_vm_list "$index")
    for vm in "${vms[@]+"${vms[@]}"}"; do
      [[ $vm =~ $RE_VM_ID ]] || continue
      now=$(date +%s)
      if is_due "$index" "$vm" "$now"; then
        run_vm "$index" "$vm" "$now"
      fi
    done
  done
  return 0
}

run_named_job() {
  local wanted=$1 index
  acquire_lock || { printf 'Another backup is running.\n' >&2; return 1; }
  load_config || { printf 'config.ini: %s\n' "$CONFIG_ERROR" >&2; return 1; }
  load_vm_list
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    if [[ ${JOB["$index.id"]} == "$wanted" ]]; then
      VERBOSE=1
      run_job_now "$index"
      return
    fi
  done
  printf 'Unknown job: %s\n' "$(safe_text "$wanted")" >&2
  return 2
}

print_help() {
  sed -n '3,16p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

main() {
  local action=tui argument="" assume_yes=0
  while (($# > 0)); do
    case "$1" in
      --run) action=run; shift ;;
      --now) action=now; argument=${2:-}; shift 2 || exit 2 ;;
      --ova) action=ova; argument=${2:-}; shift 2 || exit 2 ;;
      --restore) action=restore; argument=${2:-}; shift 2 || exit 2 ;;
      --check) action=check; shift ;;
      --update) action=update; shift ;;
      --yes) assume_yes=1; shift ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      -h | --help) print_help; exit 0 ;;
      *) printf 'Unknown option: %s\n' "$(safe_text "$1")" >&2; exit 2 ;;
    esac
  done

  if [[ $(id -u) != 0 ]]; then
    printf 'Please run this as root: sudo bash %s\n' "$SCRIPT_PATH" >&2
    exit 2
  fi

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP

  trim_log
  case "$action" in
    run) run_scheduled ;;
    now) run_named_job "$argument" ;;
    check) run_check ;;
    update) cli_update "$assume_yes" ;;
    restore) cli_restore "$argument" "$assume_yes" || exit 1 ;;
    ova)
      acquire_lock || { printf 'Another backup is running.\n' >&2; exit 1; }
      VERBOSE=1
      if build_ova "$argument"; then
        printf 'OVA created: %s\n' "$LAST_OVA"
      else
        printf 'OVA failed: %s\n' "$LAST_ERROR" >&2
        exit 1
      fi
      ;;
    tui)
      if [[ -t 0 && -t 1 ]]; then
        tui_main
      else
        print_help
        exit 2
      fi
      ;;
  esac
}

# Sourcing the file gives tests access to the functions without running anything.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
