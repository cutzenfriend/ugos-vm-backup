#!/usr/bin/env bash
#
# ugvm-backup - scheduled VM backups for UGOS. Runs as root from cron.
#
# This file is the security boundary of the app. The web app runs unprivileged
# in a sandbox and can only change config.ini, so everything read from the
# config folder is untrusted data: it is parsed line by line, validated against
# allowlists and never sourced or evaluated.
#
# Usage: ugvm-backup --config DIR [--state-dir DIR] [--check]
#        ugvm-backup --version

set -u
set -o pipefail
# Since bash 5.2 "&" in a ${var//x/y} replacement means the match, which would
# break every escaping function below.
shopt -u patsub_replacement 2>/dev/null

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LIBVIRT_DEFAULT_URI=qemu:///system
umask 077

readonly VERSION="1.0.1"
readonly CONFIG_FORMAT=1
readonly MAX_CONFIG_BYTES=65536
readonly MAX_JOBS=32
readonly MAX_LISTED_BACKUPS=500
readonly RETRY_AFTER_SECONDS=3600
readonly SHUTDOWN_TIMEOUT_SECONDS=600
readonly BACKUP_TIMEOUT_SECONDS=86400
readonly PUBLISH_EVERY_SECONDS=60

readonly RE_JOB_ID='^[a-z0-9][a-z0-9-]{0,31}$'
readonly RE_VM_ID='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly RE_DISK_TARGET='^[a-z][a-z0-9]{0,15}$'
readonly RE_COUNT='^(0|[1-9][0-9]{0,3})$'
readonly RE_HOURS='^[1-9][0-9]{0,3}$'
readonly RE_TIME='^([01][0-9]|2[0-3]):[0-5][0-9]$'
readonly RE_VOLUME_PATH='^/volume[0-9]+(/[^/]+)+$'
readonly RE_EPOCH='^[0-9]{1,12}$'
readonly RE_BYTES='^[0-9]{1,20}$'

CONFIG_DIR=""
STATE_DIR="/var/lib/ugvm-backup"
CHECK_ONLY=0

declare -A JOB=()
JOB_INDEXES=()
CONFIG_ERROR=""
JOB_ERRORS_JSON=""
VM_IDS=()

STATE_NAME="idle"
CURRENT_JOB=""
CURRENT_VM=""
CURRENT_STEP=""
LAST_PUBLISH=0
INVENTORY_VMS_JSON="[]"
INVENTORY_BACKUPS_JSON="[]"
INVENTORY_SNAPSHOTS_JSON="[]"
CAP_LIVE_BACKUP="false"
CAP_QEMU_IMG="false"

STAGING=""
CHILD_PID=""
BACKUP_JOB_VM=""
FROZEN_VM=""
RESTART_VM=""
LAST_ERROR=""
TMP_FILES=()

# --- Logging and small helpers ------------------------------------------------

log_event() {
  local level=$1 message=${2//[[:cntrl:]]/ }
  printf '%s|%s|%s\n' "$(date +%s)" "$level" "$message" >>"$STATE_DIR/log" 2>/dev/null
  [[ $CHECK_ONLY -eq 1 ]] && printf '%s: %s\n' "$level" "$message"
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
  file=$(mktemp "$STATE_DIR/tmp/XXXXXXXX") || return 1
  TMP_FILES+=("$file")
  printf '%s' "$file"
}

json_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//[[:cntrl:]]/ }
  printf '"%s"' "$value"
}

# --- Path validation ----------------------------------------------------------

# True for /volumeN/... paths with no ".", "..", control characters or system
# ("@") folders, which keeps backups away from @kvm, @appstore and the like.
is_allowed_path() {
  local path=$1 part
  [[ $path =~ [[:cntrl:]] ]] && return 1
  [[ $path =~ $RE_VOLUME_PATH ]] || return 1
  local IFS=/
  # shellcheck disable=SC2086 # Splitting on "/" is the point, globbing is off below.
  set -f
  set -- $path
  set +f
  for part in "$@"; do
    case "$part" in
      . | .. | @*) return 1 ;;
    esac
  done
  return 0
}

# Prints the fully resolved directory. Symlinks must not lead out of the allowed
# area, otherwise a writable shared folder could redirect root's writes.
resolve_allowed_dir() {
  local path=$1 resolved
  is_allowed_path "$path" || return 1
  resolved=$(realpath -e -- "$path" 2>/dev/null) || return 1
  [[ -d $resolved ]] || return 1
  is_allowed_path "$resolved" || return 1
  printf '%s' "$resolved"
}

# --- Config parsing -----------------------------------------------------------

add_job_error() {
  local id=$1 message=$2
  [[ -n $JOB_ERRORS_JSON ]] && JOB_ERRORS_JSON+=","
  JOB_ERRORS_JSON+="{\"id\":$(json_string "$id"),\"error\":$(json_string "$message")}"
}

# Invalid jobs are reported and skipped, valid jobs keep running. A broken file
# as a whole stops everything, because its contents cannot be trusted.
load_config() {
  JOB=()
  JOB_INDEXES=()
  CONFIG_ERROR=""
  JOB_ERRORS_JSON=""
  parse_config && return 0
  JOB=()
  JOB_INDEXES=()
  return 1
}

parse_config() {
  local file="$CONFIG_DIR/config.ini" line key value number=0 index=-1 version=""

  if [[ -L $file || ! -f $file ]]; then
    CONFIG_ERROR="config.ini is missing or not a regular file"
    return 1
  fi
  if (($(stat -c %s -- "$file") > MAX_CONFIG_BYTES)); then
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
      id | name | type | enabled | interval_hours | at | vms | target | keep_count | keep_days | running_vm)
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
  done <"$file"

  if [[ $version != "$CONFIG_FORMAT" ]]; then
    CONFIG_ERROR="Unsupported config version, update the script"
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
  local index=$1 type hours resolved vm
  type=${JOB["$index.type"]:-}
  case "$type" in
    snapshot | file | ova) ;;
    *) fail "Invalid type"; return 1 ;;
  esac
  case "${JOB["$index.enabled"]:-}" in
    0 | 1) ;;
    *) fail "Invalid value for enabled"; return 1 ;;
  esac

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

  if [[ $type != snapshot ]]; then
    resolved=$(resolve_allowed_dir "${JOB["$index.target"]:-}") || {
      fail "Target folder is not allowed or does not exist"
      return 1
    }
    JOB["$index.target"]=$resolved
    case "${JOB["$index.running_vm"]:-}" in
      live | shutdown | skip) ;;
      *) fail "Invalid setting for running VMs"; return 1 ;;
    esac
  fi
  return 0
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

state_file() { printf '%s/jobs/%s.%s' "$STATE_DIR" "$1" "$2"; }

state_load() {
  local file key value
  file=$(state_file "$1" "$2")
  S_FIRST=0 S_ATTEMPT=0 S_SUCCESS=0 S_DONE=0 S_RESULT="" S_ERROR=""
  [[ -f $file ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      first) S_FIRST=$value ;;
      attempt) S_ATTEMPT=$value ;;
      success) S_SUCCESS=$value ;;
      done) S_DONE=$value ;;
      result) S_RESULT=$value ;;
      error) S_ERROR=$value ;;
    esac
  done <"$file"
  return 0
}

state_save() {
  local file tmp
  file=$(state_file "$1" "$2")
  tmp=$(mktemp "$file.XXXXXX") || return 1
  printf 'first=%s\nattempt=%s\nsuccess=%s\ndone=%s\nresult=%s\nerror=%s\n' \
    "$S_FIRST" "$S_ATTEMPT" "$S_SUCCESS" "$S_DONE" "$S_RESULT" "${S_ERROR//[[:cntrl:]]/ }" >"$tmp"
  mv -f -- "$tmp" "$file"
}

# A new job waits for its next scheduled time instead of starting immediately,
# so that saving a job can never shut down a VM in the middle of the day.
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

prune_file_backups() {
  local index=$1 vm=$2 now=$3 job type base dir name stamp epoch
  job=${JOB["$index.id"]}
  type=${JOB["$index.type"]}
  base="${JOB["$index.target"]}/$vm"
  local pattern="^$type-$job-([0-9]{8})-([0-9]{6})\$"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    log_event info "Retention: deleting $vm/$name"
    rm -rf --one-file-system -- "${base:?}/$name" ||
      log_event error "Could not delete $vm/$name"
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

# Runs a command in the background so the status heartbeat keeps going and a
# signal can stop it. The command's last error line ends up in LAST_ERROR.
run_long() {
  local err code
  err=$(new_private_file) || return 1
  "$@" >/dev/null 2>"$err" &
  CHILD_PID=$!
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    /bin/sleep 1
    publish_status_if_stale
  done
  wait "$CHILD_PID"
  code=$?
  CHILD_PID=""
  ((code == 0)) || LAST_ERROR=$(last_line "$err")
  return "$code"
}

# --- VM information -----------------------------------------------------------

vm_state() { virsh domstate --domain "$1" 2>/dev/null | head -n 1; }

vm_title() {
  local title
  title=$(virsh desc --domain "$1" --title 2>/dev/null | head -n 1)
  [[ $title == "No title"* ]] && title=""
  printf '%s' "${title//[[:cntrl:]]/ }"
}

DISK_TARGETS=()
DISK_PATHS=()
DISK_FORMATS=()

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
    [[ $type == file || $type == block ]] || { fail "Disk $target: type $type is not supported"; return 1; }
    [[ $target =~ $RE_DISK_TARGET ]] || { fail "Unexpected disk name"; return 1; }
    [[ $source == /* && ! $source =~ [[:cntrl:]] ]] || { fail "Unexpected disk path"; return 1; }
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

xml_escape() {
  local value=$1
  value=${value//&/&amp;}
  value=${value//</&lt;}
  value=${value//>/&gt;}
  value=${value//\'/&apos;}
  value=${value//\"/&quot;}
  printf '%s' "$value"
}

capture_live() {
  local vm=$1 dest=$2 xml_file index
  xml_file=$(new_private_file) || { fail "Could not create a temporary file"; return 1; }
  {
    printf "<domainbackup mode='push'>\n  <disks>\n"
    for index in "${!DISK_TARGETS[@]}"; do
      printf "    <disk name='%s' backup='yes' type='file'>\n" "${DISK_TARGETS[$index]}"
      printf "      <target file='%s'/>\n      <driver type='qcow2'/>\n    </disk>\n" \
        "$(xml_escape "$dest/${DISK_TARGETS[$index]}.qcow2")"
    done
    printf '  </disks>\n</domainbackup>\n'
  } >"$xml_file"

  local job_state
  job_state=$(virsh domjobinfo --domain "$vm" 2>/dev/null | awk -F': *' '/^Job type/ {sub(/ +$/, "", $2); print $2}')
  if [[ -n $job_state && $job_state != None ]]; then
    fail "Another operation is already running on this VM"
    return 1
  fi

  # Freezing is only needed while the backup starts: QEMU's point in time is
  # fixed from then on. Without a guest agent the result is crash-consistent.
  CONSISTENCY="crash"
  if [[ -n ${HAS_GUEST_AGENT:-} ]] && virsh domfsfreeze --domain "$vm" >/dev/null 2>&1; then
    FROZEN_VM=$vm
    CONSISTENCY="filesystem"
  fi

  local err begin_code
  err=$(new_private_file) || err=/dev/null
  BACKUP_JOB_VM=$vm
  virsh backup-begin --domain "$vm" --backupxml "$xml_file" >/dev/null 2>"$err"
  begin_code=$?
  if [[ -n $FROZEN_VM ]]; then
    virsh domfsthaw --domain "$vm" >/dev/null 2>&1 || log_event error "Could not thaw the file system of $vm"
    FROZEN_VM=""
  fi
  if ((begin_code != 0)); then
    BACKUP_JOB_VM=""
    fail "Live backup not possible: $(last_line "$err")"
    return 1
  fi

  local started=$SECONDS
  while :; do
    job_state=$(virsh domjobinfo --domain "$vm" 2>/dev/null | awk -F': *' '/^Job type/ {sub(/ +$/, "", $2); print $2}')
    [[ -z $job_state || $job_state == None ]] && break
    if ((SECONDS - started > BACKUP_TIMEOUT_SECONDS)); then
      virsh domjobabort --domain "$vm" >/dev/null 2>&1
      BACKUP_JOB_VM=""
      fail "Live backup exceeded the time limit"
      return 1
    fi
    publish_status_if_stale
    /bin/sleep 5
  done
  BACKUP_JOB_VM=""

  # Only an explicit "Completed" counts: an aborted copy can still be a
  # structurally valid qcow2 file and would pass "qemu-img check" below.
  job_state=$(virsh domjobinfo --domain "$vm" --completed 2>/dev/null | awk -F': *' '/^Job type/ {sub(/ +$/, "", $2); print $2}')
  [[ $job_state == Completed ]] || { fail "Live backup did not finish successfully (${job_state:-no status})"; return 1; }
  return 0
}

capture_offline() {
  local dest=$1 index
  CONSISTENCY="offline"
  for index in "${!DISK_TARGETS[@]}"; do
    CURRENT_STEP="Copying disk ${DISK_TARGETS[$index]}"
    publish_status
    run_long qemu-img convert -f "${DISK_FORMATS[$index]}" -O qcow2 \
      -- "${DISK_PATHS[$index]}" "$dest/${DISK_TARGETS[$index]}.qcow2" || {
      fail "Could not copy disk ${DISK_TARGETS[$index]}: $LAST_ERROR"
      return 1
    }
  done
}

verify_captured() {
  local dest=$1 target
  for target in "${DISK_TARGETS[@]}"; do
    CURRENT_STEP="Checking disk $target"
    publish_status
    run_long qemu-img check -f qcow2 -- "$dest/$target.qcow2" || {
      fail "Check of disk $target failed: $LAST_ERROR"
      return 1
    }
  done
}

shutdown_vm() {
  local vm=$1 waited=0
  CURRENT_STEP="Shutting down VM"
  publish_status
  virsh shutdown --domain "$vm" >/dev/null 2>&1 || { fail "Could not shut down the VM"; return 1; }
  RESTART_VM=$vm
  while [[ $(vm_state "$vm") != "shut off" ]]; do
    if ((waited >= SHUTDOWN_TIMEOUT_SECONDS)); then
      # The VM is never forced off: that would risk the data this job protects.
      RESTART_VM=""
      fail "VM did not shut down within $((SHUTDOWN_TIMEOUT_SECONDS / 60)) minutes"
      return 1
    fi
    /bin/sleep 5
    waited=$((waited + 5))
    publish_status_if_stale
  done
}

restart_vm_if_needed() {
  [[ -n $RESTART_VM ]] || return 0
  local vm=$RESTART_VM
  RESTART_VM=""
  if virsh start --domain "$vm" >/dev/null 2>&1; then
    log_event info "VM $vm started again"
  else
    log_event error "Could not start VM $vm again"
  fi
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

# --- OVA ----------------------------------------------------------------------

write_ovf() {
  local vm=$1 title=$2 dest=$3 is_uefi=$4 cpus memory_kib disk_refs="" disk_defs="" items="" nics index=0 target
  cpus=$(virsh dominfo --domain "$vm" 2>/dev/null | awk -F': *' '/^CPU\(s\)/ {print $2}')
  memory_kib=$(virsh dominfo --domain "$vm" 2>/dev/null | awk '/^Max memory/ {print $3}')
  [[ $cpus =~ ^[0-9]+$ && $memory_kib =~ ^[0-9]+$ ]] || { fail "Can't read the VM's CPU and RAM"; return 1; }

  local instance=4 file size capacity
  for target in "${DISK_TARGETS[@]}"; do
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

  nics=$(virsh domiflist --domain "$vm" 2>/dev/null | tail -n +3 | grep -c .)
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
  safe_title=$(xml_escape "${title:-$vm}")

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

build_ova() {
  local vm=$1 title=$2 dest=$3 is_uefi=$4 target files=() file
  for target in "${DISK_TARGETS[@]}"; do
    CURRENT_STEP="Converting disk $target for OVA"
    publish_status
    run_long qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized \
      -- "$dest/$target.qcow2" "$dest/$target.vmdk" || {
      fail "OVA conversion failed: $LAST_ERROR"
      return 1
    }
    rm -f -- "$dest/$target.qcow2"
    files+=("$target.vmdk")
  done

  CURRENT_STEP="Creating OVA"
  publish_status
  write_ovf "$vm" "$title" "$dest" "$is_uefi" || return 1
  (
    cd -- "$dest" || exit 1
    : >vm.mf
    for file in vm.ovf "${files[@]}"; do
      printf 'SHA256(%s)= %s\n' "$file" "$(sha256sum -- "$file" | cut -d' ' -f1)" >>vm.mf
    done
  ) || { fail "Could not create checksums"; return 1; }
  # The OVF specification requires the descriptor to be the first file.
  run_long tar --format=ustar -C "$dest" -cf "$dest/vm.ova" -- vm.ovf vm.mf "${files[@]}" || {
    fail "Could not create the OVA archive: $LAST_ERROR"
    return 1
  }
  for file in vm.ovf vm.mf "${files[@]}"; do
    rm -f -- "${dest:?}/$file"
  done
}

# --- One backup of one VM -----------------------------------------------------

check_free_space() {
  local dest_parent=$1 factor=$2 needed=0 path used available
  for path in "${DISK_PATHS[@]}"; do
    used=$(du -sB1 -- "$path" 2>/dev/null | cut -f1)
    [[ $used =~ $RE_BYTES ]] && needed=$((needed + used))
  done
  needed=$((needed * factor + needed / 10))
  available=$(df --output=avail -B1 -- "$dest_parent" 2>/dev/null | tail -n 1 | tr -d ' ')
  [[ $available =~ $RE_BYTES ]] || { fail "Could not determine free space"; return 1; }
  if ((available < needed)); then
    fail "Not enough space in the target: $((available / 1073741824)) GiB free, about $((needed / 1073741824)) GiB needed"
    return 1
  fi
}

# Prepares <target>/<vm>. A symlink here would let anyone with write access to
# the shared folder redirect root's writes, so anything unexpected is refused.
prepare_vm_dir() {
  local target=$1 vm=$2 dir="$1/$2"
  if [[ -L $dir || (-e $dir && ! -d $dir) ]]; then
    fail "This VM's folder in the target is not a regular folder"
    return 1
  fi
  mkdir -p -- "$dir" || { fail "Could not create the folder in the target"; return 1; }
  [[ $(realpath -e -- "$dir") == "$dir" ]] || { fail "The folder in the target points somewhere else"; return 1; }
  chown -h --reference="$target" -- "$dir"
  chmod 0751 -- "$dir"
}

backup_to_folder() {
  local index=$1 vm=$2 now=$3 job type target running_mode state title is_uefi xml
  job=${JOB["$index.id"]}
  type=${JOB["$index.type"]}
  target=${JOB["$index.target"]}
  running_mode=${JOB["$index.running_vm"]}

  # Revalidated on every run: the folder could have been replaced by a symlink
  # since the config was read.
  target=$(resolve_allowed_dir "$target") || { fail "Target folder is not allowed or does not exist"; return 1; }

  load_disks "$vm" || return 1
  state=$(vm_state "$vm")
  title=$(vm_title "$vm")
  xml=$(virsh dumpxml --inactive --domain "$vm" 2>/dev/null)
  is_uefi=false
  grep -qE '<nvram|<loader' <<<"$xml" && is_uefi=true
  HAS_GUEST_AGENT=""
  grep -q 'org.qemu.guest_agent' <<<"$xml" && HAS_GUEST_AGENT=1

  local mode
  case "$state" in
    "shut off") mode=offline ;;
    running | paused)
      case "$running_mode" in
        live) mode=live ;;
        shutdown) mode=shutdown ;;
        skip) return 2 ;;
      esac
      ;;
    *) fail "VM is in state ${state:-unknown}"; return 1 ;;
  esac

  prepare_vm_dir "$target" "$vm" || return 1
  local factor=1
  [[ $type == ova && $mode == live ]] && factor=2
  check_free_space "$target" "$factor" || return 1

  # A crash can leave a partial folder behind. This run holds the lock, so any
  # partial folder of this job is left over from an earlier run.
  local leftover
  for leftover in "$target/$vm/.partial-$type-$job-"*; do
    [[ -d $leftover && ! -L $leftover ]] && rm -rf --one-file-system -- "$leftover"
  done

  local name
  name="$type-$job-$(date -d "@$now" +%Y%m%d-%H%M%S)"
  STAGING="$target/$vm/.partial-$name"
  mkdir -m 0711 -- "$STAGING" || { STAGING=""; fail "Could not create the working folder"; return 1; }

  case "$mode" in
    live)
      CURRENT_STEP="Live backup running"
      publish_status
      capture_live "$vm" "$STAGING" || return 1
      ;;
    offline)
      capture_offline "$STAGING" || return 1
      ;;
    shutdown)
      shutdown_vm "$vm" || return 1
      capture_offline "$STAGING"
      local capture_code=$?
      restart_vm_if_needed
      ((capture_code == 0)) || return 1
      ;;
  esac

  verify_captured "$STAGING" || return 1
  copy_vm_metadata "$vm" "$STAGING" || return 1
  [[ $type == ova ]] && { build_ova "$vm" "$title" "$STAGING" "$is_uefi" || return 1; }

  local size
  size=$(du -sB1 -- "$STAGING" | cut -f1)
  {
    printf 'format=1\nid=%s\njob=%s\ntype=%s\nvm=%s\ntitle=%s\n' "$name" "$job" "$type" "$vm" "$title"
    printf 'created=%s\nconsistency=%s\nsize=%s\nscript_version=%s\n' "$now" "$CONSISTENCY" "$size" "$VERSION"
  } >"$STAGING/manifest.txt"

  # Finished backups belong to the owner of the shared folder, so they can be
  # restored with normal tools.
  find -P "$STAGING" -type d -exec chmod 0750 {} +
  find -P "$STAGING" -type f -exec chmod 0640 {} +
  chown -hR --reference="$target" -- "$STAGING"

  # The final name only exists for complete, verified backups.
  mv -T -- "$STAGING" "$target/$vm/$name" || { fail "Could not finish the backup"; return 1; }
  STAGING=""
  log_event info "Backup finished: $vm/$name ($CONSISTENCY)"
  return 0
}

take_snapshot() {
  local index=$1 vm=$2 now=$3 err
  err=$(new_private_file) || err=/dev/null
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

  STATE_NAME="running"
  CURRENT_JOB=$job
  CURRENT_VM=$vm
  CURRENT_STEP="Starting"
  LAST_ERROR=""
  publish_status

  if [[ " ${VM_IDS[*]+"${VM_IDS[*]}"} " != *" $vm "* ]]; then
    fail "VM not found"
    code=1
  elif [[ ${JOB["$index.type"]} == snapshot ]]; then
    CURRENT_STEP="Creating snapshot"
    publish_status
    take_snapshot "$index" "$vm" "$attempt_now" || code=1
  else
    backup_to_folder "$index" "$vm" "$attempt_now"
    code=$?
  fi

  restart_vm_if_needed
  discard_staging

  state_load "$job" "$vm"
  S_ATTEMPT=$attempt_now
  case "$code" in
    0)
      S_SUCCESS=$(date +%s)
      S_DONE=$S_SUCCESS
      S_RESULT="ok"
      # Retention runs only after a success, so a failing job can never eat
      # through the backups that are still good.
      CURRENT_STEP="Applying retention"
      publish_status
      if [[ ${JOB["$index.type"]} == snapshot ]]; then
        prune_snapshots "$index" "$vm" "$(date +%s)"
      else
        prune_file_backups "$index" "$vm" "$(date +%s)"
      fi
      ;;
    2)
      S_DONE=$(date +%s)
      S_RESULT="skipped"
      log_event info "$vm is running, job $job skipped"
      ;;
    *)
      S_RESULT="error"
      S_ERROR=$LAST_ERROR
      log_event error "Job $job, VM $vm: $LAST_ERROR"
      ;;
  esac
  state_save "$job" "$vm"

  STATE_NAME="idle"
  CURRENT_JOB=""
  CURRENT_VM=""
  CURRENT_STEP=""
  build_inventory
  publish_status
}

discard_staging() {
  if [[ -n $STAGING ]]; then
    [[ -d $STAGING && ! -L $STAGING ]] && rm -rf --one-file-system -- "$STAGING"
    STAGING=""
  fi
}

# --- Status for the web app ---------------------------------------------------

job_vm_list() {
  local index=$1 vms=${JOB["$1.vms"]}
  if [[ $vms == "*" ]]; then
    printf '%s\n' "${VM_IDS[@]+"${VM_IDS[@]}"}"
  else
    tr ',' '\n' <<<"$vms"
  fi
}

build_inventory() {
  local items="" vm xml state title uefi agent disks names=()
  VM_IDS=()
  mapfile -t names < <(virsh list --all --name 2>/dev/null)
  for vm in "${names[@]+"${names[@]}"}"; do
    [[ $vm =~ $RE_VM_ID ]] || continue
    VM_IDS+=("$vm")
    xml=$(virsh dumpxml --inactive --domain "$vm" 2>/dev/null)
    state=$(vm_state "$vm")
    title=$(vm_title "$vm")
    uefi=false agent=false
    grep -qE '<nvram|<loader' <<<"$xml" && uefi=true
    grep -q 'org.qemu.guest_agent' <<<"$xml" && agent=true
    disks=$(virsh domblklist --domain "$vm" --details 2>/dev/null | awk 'NR > 2 && $2 == "disk"' | grep -c .)
    [[ -n $items ]] && items+=","
    items+="{\"id\":$(json_string "$vm"),\"title\":$(json_string "$title"),\"state\":$(json_string "$state"),\"disks\":${disks:-0},\"uefi\":$uefi,\"guest_agent\":$agent}"
  done
  INVENTORY_VMS_JSON="[$items]"

  # Manifests live in user-writable folders: every value is checked or escaped.
  local backups="" count=0 index target type job dir manifest name created size key value consistency pattern seen=" "
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    type=${JOB["$index.type"]}
    [[ $type == snapshot ]] && continue
    job=${JOB["$index.id"]}
    target=${JOB["$index.target"]}
    [[ $seen == *" $job "* ]] && continue
    seen+="$job "
    pattern="^$type-$job-[0-9]{8}-[0-9]{6}\$"
    for dir in "$target"/*/"$type-$job-"*; do
      name=${dir##*/}
      [[ $name =~ $pattern && -d $dir && ! -L $dir ]] || continue
      manifest="$dir/manifest.txt"
      [[ -f $manifest && ! -L $manifest ]] || continue
      vm=${dir%/*}
      vm=${vm##*/}
      [[ $vm =~ $RE_VM_ID ]] || continue
      created=0 size=0 consistency=""
      while IFS='=' read -r key value; do
        case "$key" in
          created) [[ $value =~ $RE_EPOCH ]] && created=$value ;;
          size) [[ $value =~ $RE_BYTES ]] && size=$value ;;
          consistency) [[ $value =~ ^[a-z]{1,16}$ ]] && consistency=$value ;;
        esac
      done < <(head -c 4096 -- "$manifest")
      ((count >= MAX_LISTED_BACKUPS)) && break 2
      count=$((count + 1))
      [[ -n $backups ]] && backups+=","
      backups+="{\"id\":$(json_string "$name"),\"job\":$(json_string "$job"),\"vm\":$(json_string "$vm"),\"type\":\"$type\",\"created\":$created,\"size\":$size,\"consistency\":\"$consistency\"}"
    done
  done
  INVENTORY_BACKUPS_JSON="[$backups]"

  local snapshots="" epoch job_vms=()
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    [[ ${JOB["$index.type"]} == snapshot ]] || continue
    job=${JOB["$index.id"]}
    mapfile -t job_vms < <(job_vm_list "$index")
    for vm in "${job_vms[@]+"${job_vms[@]}"}"; do
      [[ $vm =~ $RE_VM_ID ]] || continue
      [[ " ${VM_IDS[*]+"${VM_IDS[*]}"} " == *" $vm "* ]] || continue
      while read -r epoch name; do
        [[ -n $snapshots ]] && snapshots+=","
        snapshots+="{\"id\":$(json_string "$name"),\"job\":$(json_string "$job"),\"vm\":$(json_string "$vm"),\"type\":\"snapshot\",\"created\":$epoch}"
      done < <(list_job_snapshots "$vm" "$job")
    done
  done
  INVENTORY_SNAPSHOTS_JSON="[$snapshots]"
}

build_jobs_json() {
  local out="" index job vm entries now slot
  now=$(date +%s)
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    job=${JOB["$index.id"]}
    entries=""
    slot=$(latest_slot "${JOB["$index.interval_hours"]}" "${JOB["$index.at"]}" "$now")
    while IFS= read -r vm; do
      [[ $vm =~ $RE_VM_ID ]] || continue
      state_load "$job" "$vm"
      [[ -n $entries ]] && entries+=","
      entries+="{\"vm\":$(json_string "$vm"),\"last_success\":$S_SUCCESS,\"last_attempt\":$S_ATTEMPT,\"result\":$(json_string "$S_RESULT"),\"error\":$(json_string "$S_ERROR")}"
    done < <(job_vm_list "$index")
    [[ -n $out ]] && out+=","
    out+="{\"id\":$(json_string "$job"),\"enabled\":${JOB["$index.enabled"]},\"next_run\":$((slot + ${JOB["$index.interval_hours"]} * 3600)),\"vms\":[$entries]}"
  done
  printf '[%s]' "$out"
}

build_log_json() {
  local out="" time level message
  [[ -f $STATE_DIR/log ]] || { printf '[]'; return 0; }
  while IFS='|' read -r time level message; do
    [[ $time =~ $RE_EPOCH ]] || continue
    [[ -n $out ]] && out+=","
    out+="{\"time\":$time,\"level\":$(json_string "$level"),\"message\":$(json_string "$message")}"
  done < <(tail -n 50 -- "$STATE_DIR/log")
  printf '[%s]' "$out"
}

# Written next to config.ini, a folder the app and possibly other users can
# write to. mktemp never follows a planted link, and rename replaces a symlink
# at the destination instead of writing through it.
publish_status() {
  local tmp now
  [[ -n $CONFIG_DIR ]] || return 0
  ((CHECK_ONLY == 1)) && return 0
  tmp=$(mktemp "$CONFIG_DIR/.status.XXXXXXXX" 2>/dev/null) || return 0
  now=$(date +%s)
  {
    printf '{"format":1,"script_version":"%s","heartbeat":%s,"state":"%s",' "$VERSION" "$now" "$STATE_NAME"
    printf '"current":{"job":%s,"vm":%s,"step":%s},' \
      "$(json_string "$CURRENT_JOB")" "$(json_string "$CURRENT_VM")" "$(json_string "$CURRENT_STEP")"
    printf '"capabilities":{"live_backup":%s,"qemu_img":%s},' "$CAP_LIVE_BACKUP" "$CAP_QEMU_IMG"
    printf '"config_error":%s,"job_errors":[%s],' "$(json_string "$CONFIG_ERROR")" "$JOB_ERRORS_JSON"
    printf '"vms":%s,"jobs":%s,"backups":%s,"snapshots":%s,"log":%s}\n' \
      "$INVENTORY_VMS_JSON" "$(build_jobs_json)" "$INVENTORY_BACKUPS_JSON" \
      "$INVENTORY_SNAPSHOTS_JSON" "$(build_log_json)"
  } >"$tmp"
  chown --reference="$CONFIG_DIR" -- "$tmp" 2>/dev/null
  chmod 0640 -- "$tmp"
  mv -T -f -- "$tmp" "$CONFIG_DIR/status.json" 2>/dev/null || rm -f -- "$tmp"
  LAST_PUBLISH=$now
}

publish_status_if_stale() {
  local now
  now=$(date +%s)
  ((now - LAST_PUBLISH >= PUBLISH_EVERY_SECONDS)) && publish_status
  return 0
}

# --- Startup checks -----------------------------------------------------------

# A root cron job must not run anything others can change, so the script refuses
# to start from a location that would turn write access into root access.
is_root_only() {
  local path=$1 owner perms
  owner=$(stat -c %u -- "$path" 2>/dev/null) || return 1
  perms=$(stat -c %a -- "$path" 2>/dev/null) || return 1
  [[ $owner == 0 ]] && (((8#$perms & 8#022) == 0))
}

check_self_is_protected() {
  local self
  self=$(realpath -e -- "${BASH_SOURCE[0]}") || return 1
  is_root_only "$self" && is_root_only "$(dirname -- "$self")"
}

prepare_state_dir() {
  if [[ -L $STATE_DIR ]]; then
    printf 'state dir must not be a symlink: %s\n' "$STATE_DIR" >&2
    return 1
  fi
  mkdir -p -- "$STATE_DIR/jobs" "$STATE_DIR/tmp" || return 1
  chmod 0700 -- "$STATE_DIR"
  is_root_only "$STATE_DIR" || {
    printf 'state dir must be owned by root: %s\n' "$STATE_DIR" >&2
    return 1
  }
  rm -f -- "$STATE_DIR"/tmp/*
  if [[ -f $STATE_DIR/log ]] && (($(stat -c %s -- "$STATE_DIR/log") > 262144)); then
    local trimmed
    trimmed=$(mktemp "$STATE_DIR/tmp/XXXXXXXX") &&
      tail -n 1000 -- "$STATE_DIR/log" >"$trimmed" &&
      mv -f -- "$trimmed" "$STATE_DIR/log"
  fi
}

detect_capabilities() {
  CAP_LIVE_BACKUP=false
  CAP_QEMU_IMG=false
  command -v qemu-img >/dev/null 2>&1 && CAP_QEMU_IMG=true
  virsh domcapabilities 2>/dev/null | grep -qE "<backup supported=.yes." && CAP_LIVE_BACKUP=true
  return 0
}

on_exit() {
  local code=$?
  trap - EXIT TERM INT HUP
  [[ -n $CHILD_PID ]] && kill "$CHILD_PID" 2>/dev/null
  [[ -n $BACKUP_JOB_VM ]] && virsh domjobabort --domain "$BACKUP_JOB_VM" >/dev/null 2>&1
  [[ -n $FROZEN_VM ]] && virsh domfsthaw --domain "$FROZEN_VM" >/dev/null 2>&1
  restart_vm_if_needed
  discard_staging
  rm -f -- "${TMP_FILES[@]+"${TMP_FILES[@]}"}"
  if [[ $STATE_NAME == running ]]; then
    log_event error "Run was interrupted (job $CURRENT_JOB, VM $CURRENT_VM)"
    STATE_NAME="idle"
    CURRENT_JOB="" CURRENT_VM="" CURRENT_STEP=""
    publish_status
  fi
  exit "$code"
}

# Requests are empty files named after a job. The name is the only input.
take_requests() {
  local dir="$CONFIG_DIR/requests" file name
  REQUESTED=" "
  [[ -d $dir && ! -L $dir ]] || return 0
  for file in "$dir"/*; do
    name=${file##*/}
    [[ $name =~ $RE_JOB_ID && -f $file && ! -L $file ]] || continue
    rm -f -- "$file"
    REQUESTED+="$name "
  done
}

run_check() {
  printf 'ugvm-backup %s\n' "$VERSION"
  printf 'config folder: %s\n' "$CONFIG_DIR"
  printf 'qemu-img: %s\nlive backup: %s\nVMs: %s\n' "$CAP_QEMU_IMG" "$CAP_LIVE_BACKUP" "${#VM_IDS[@]}"
  if [[ -n $CONFIG_ERROR ]]; then
    printf 'config: ERROR: %s\n' "$CONFIG_ERROR"
    return 1
  fi
  printf 'valid jobs: %s\n' "${#JOB_INDEXES[@]}"
  return 0
}

main() {
  while (($# > 0)); do
    case "$1" in
      --config) CONFIG_DIR=${2:-}; shift 2 || exit 2 ;;
      --state-dir) STATE_DIR=${2:-}; shift 2 || exit 2 ;;
      --check) CHECK_ONLY=1; shift ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done

  if [[ $(id -u) != 0 ]]; then
    printf 'must run as root\n' >&2
    exit 2
  fi
  if ! check_self_is_protected; then
    printf 'refusing to run: this script and its folder must be owned by root and not writable by others\n' >&2
    exit 2
  fi
  local requested_config=$CONFIG_DIR
  CONFIG_DIR=$(resolve_allowed_dir "$requested_config") || {
    CONFIG_DIR=""
    printf 'config folder not allowed or missing: %s\n' "${requested_config//[[:cntrl:]]/ }" >&2
    exit 2
  }
  prepare_state_dir || exit 2

  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    [[ $CHECK_ONLY -eq 1 ]] && printf 'A run is already in progress.\n'
    exit 0
  fi

  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP

  detect_capabilities
  load_config
  build_inventory

  if ((CHECK_ONLY == 1)); then
    run_check
    exit $?
  fi

  publish_status

  take_requests
  local index vm job now job_vms=()
  for index in "${JOB_INDEXES[@]+"${JOB_INDEXES[@]}"}"; do
    job=${JOB["$index.id"]}
    mapfile -t job_vms < <(job_vm_list "$index")
    for vm in "${job_vms[@]+"${job_vms[@]}"}"; do
      [[ $vm =~ $RE_VM_ID ]] || continue
      now=$(date +%s)
      if [[ $REQUESTED == *" $job "* ]]; then
        run_vm "$index" "$vm" "$now"
      elif [[ ${JOB["$index.enabled"]} == 1 ]] && is_due "$index" "$vm" "$now"; then
        run_vm "$index" "$vm" "$now"
      fi
    done
  done

  build_inventory
  publish_status
}

# Sourcing the file gives tests access to the functions without running anything.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
