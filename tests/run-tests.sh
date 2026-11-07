#!/usr/bin/env bash
#
# Tests for ugvm-backup.sh. Runs as root inside a disposable Debian 12 container
# (see tests/run-in-docker.sh), because it installs test doubles and writes to
# /volume1 and /volume2. Never run this on a real system.

set -u

if [[ ! -f /.dockerenv ]]; then
  echo "refusing to run outside a container" >&2
  exit 2
fi

SOURCE_SCRIPT=/src/ugvm-backup.sh
BASE=/volume1/VMBackup
SCRIPT=$BASE/ugvm-backup.sh
FAKE=/tmp/fakevirt
ANSWERS=/tmp/whiptail-answers

install -m 0755 /src/tests/stub-virsh /usr/bin/virsh

# The script looks in /usr/sbin first, so test doubles go there. The container's
# file system can't clone files, so "cp --reflink" becomes a normal copy that
# records whether the guest was frozen at that moment.
cat >/usr/sbin/cp <<'EOF'
#!/bin/sh
if [ "$1" = "--reflink=always" ]; then
  [ -f /tmp/fakevirt/reflink-fails ] && { echo "cp: failed to clone: Operation not supported" >&2; exit 1; }
  [ -f /tmp/fakevirt/reflink-sleeps ] && /bin/sleep 20
  for f in /tmp/fakevirt/*/frozen; do [ -f "$f" ] && touch /tmp/fakevirt/cloned-while-frozen; done
  shift
fi
exec /bin/cp "$@"
EOF
cat >/usr/sbin/crontab <<'EOF'
#!/bin/sh
case "$1" in
  -l) [ -f /tmp/fake-crontab ] && cat /tmp/fake-crontab || { echo "no crontab for root" >&2; exit 1; } ;;
  -) cat >/tmp/fake-crontab.new && mv /tmp/fake-crontab.new /tmp/fake-crontab ;;
esac
EOF
# Answers come from a file, one per call: "<exit code> <text>". Without answers
# every dialog is cancelled, so a broken flow ends instead of hanging.
cat >/usr/sbin/whiptail <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>/tmp/whiptail-calls
[ -s /tmp/whiptail-answers ] || exit 1
line=$(head -n 1 /tmp/whiptail-answers)
sed -i '1d' /tmp/whiptail-answers
printf '%b' "${line#* }" >&2
exit "${line%% *}"
EOF
# The container has no btrfs, so the file system type and attributes are faked.
cat >/usr/sbin/findmnt <<'EOF'
#!/bin/sh
if [ "$1" = "-no" ] && [ "$2" = "FSTYPE" ]; then
  if [ -f /tmp/fakevirt/not-btrfs ]; then echo ext4; else echo btrfs; fi
  exit 0
fi
exec /usr/bin/findmnt "$@"
EOF
cat >/usr/sbin/lsattr <<'EOF'
#!/bin/sh
if [ -f /tmp/fakevirt/nocow ]; then echo "---------------C------ $2"; else echo "---------------------- $2"; fi
EOF
chmod 0755 /usr/sbin/cp /usr/sbin/crontab /usr/sbin/whiptail /usr/sbin/findmnt /usr/sbin/lsattr
id -u appuser >/dev/null 2>&1 || useradd -M appuser

passed=0
failed=0
current=""

begin() {
  current=$1
  rm -f /usr/sbin/qemu-img
  rm -rf "$FAKE" /volume1 /volume2 /tmp/pwned /tmp/secret-marker /tmp/fake-crontab /tmp/whiptail-calls "$ANSWERS" /.ugvm-clone
  mkdir -p "$FAKE" "$BASE" /volume2/@kvm
  chown appuser "$BASE"
  install -o appuser -m 0755 "$SOURCE_SCRIPT" "$SCRIPT"
}

ok() { passed=$((passed + 1)); printf '  ok   %s: %s\n' "$current" "$1"; }
no() { failed=$((failed + 1)); printf '  FAIL %s: %s\n' "$current" "$1"; }
check() {
  local description=$1
  shift
  if "$@"; then ok "$description"; else no "$description"; fi
}
refute() {
  local description=$1
  shift
  if "$@"; then no "$description"; else ok "$description"; fi
}

# new_vm <id> <state> [qcow2|raw]
new_vm() {
  local vm=$1 state=$2 format=${3:-qcow2} disk
  mkdir -p "$FAKE/$vm" "/volume2/@kvm/$vm"
  echo "$state" >"$FAKE/$vm/state"
  echo "Test VM" >"$FAKE/$vm/title"
  disk="/volume2/@kvm/$vm/disk.$format"
  qemu-img create -q -f "$format" "$disk" 16M
  printf 'sda %s %s\n' "$format" "$disk" >"$FAKE/$vm/disks"
}

write_config() {
  {
    echo "version=2"
    local section
    for section in "$@"; do
      printf '[job]\n%s\n' "$section"
    done
  } >"$BASE/config.ini"
}

job() { # job <id> <type> <vms> [keep_count] [keep_days] [enabled]
  printf 'id=%s\nname=Job %s\ntype=%s\nenabled=%s\ninterval_hours=24\nat=03:00\nvms=%s\nkeep_count=%s\nkeep_days=%s' \
    "$1" "$1" "$2" "${6:-1}" "$3" "${4:-0}" "${5:-0}"
}

now_job() { "$SCRIPT" --now "$1" >/tmp/last-output 2>&1; }
tick() { "$SCRIPT" --run >/tmp/last-output 2>&1; }
vm_dir() { printf '%s/Test_VM-%s' "$BASE" "${1:0:8}"; }
backups_of() { find "$(vm_dir "$1")" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' 2>/dev/null | wc -l; }
first_backup() { find "$(vm_dir "$1")" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' | head -n 1; }
called() { grep -qE -- "$1" "$FAKE/calls"; }
state_of() { sed -n "s/^$3=//p" "$BASE/ugvm-state/$1.$2"; }
tui() { bash -c "source '$SCRIPT'; $1" >/tmp/last-output 2>&1 </dev/null; }
# The interface asks about a missing schedule first. Most tests are about something
# else, so they start with the schedule already active.
schedule_on() { bash -c "source '$SCRIPT'; cron_install" >/dev/null 2>&1 </dev/null; }
tui_main() { [[ ${1:-} == no-schedule ]] || schedule_on; tui 'tui_main'; }

echo "== live backup"

begin "live"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
now_job nightly
check "command succeeds" test "$?" = 0
dir=$(first_backup vm-a)
check "backup folder sits in a folder per VM next to the script" grep -qE "^$BASE/Test_VM-vm-a/backup-nightly-[0-9]{8}-[0-9]{6}$" <<<"$dir"
check "disk is a valid qcow2" qemu-img check -q -f qcow2 "$dir/sda.qcow2"
check "domain definition saved" test -s "$dir/domain.xml"
check "manifest records consistency" grep -q '^consistency=filesystem$' "$dir/manifest.txt"
check "guest was frozen" test -f "$FAKE/vm-a/was-frozen"
check "guest was thawed" test -f "$FAKE/vm-a/was-thawed"
check "guest is not left frozen" test ! -f "$FAKE/vm-a/frozen"
check "disk was cloned while frozen" test -f "$FAKE/cloned-while-frozen"
refute "qemu-img did not run while frozen" grep -q qemu-img "$FAKE/calls"
check "clone folder removed afterwards" test ! -e /.ugvm-clone
check "no partial folder left" test "$(find "$BASE" -name '.partial-*' | wc -l)" = 0
check "VM keeps running" test "$(cat "$FAKE/vm-a/state")" = running
refute "VM is never shut down, destroyed or started" called '^(shutdown|destroy|start|suspend|managedsave|reboot)'
check "result recorded" test "$(state_of nightly vm-a result)" = ok
check "freeze time logged" grep -q 'was frozen for' "$BASE/ugvm-backup.log"

begin "ownership"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(first_backup vm-a)
check "backup belongs to the folder owner" test "$(stat -c %U "$dir/sda.qcow2")" = appuser
check "VM folder belongs to the folder owner" test "$(stat -c %U "$(vm_dir vm-a)")" = appuser
check "log belongs to the folder owner" test "$(stat -c %U "$BASE/ugvm-backup.log")" = appuser
check "state belongs to the folder owner" test "$(stat -c %U "$BASE/ugvm-state")" = appuser

begin "no-root-owned-script-needed"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a)"
check "script owned by a normal user" test "$(stat -c %U "$SCRIPT")" = appuser
now_job nightly
check "runs from a user-owned folder" test "$(backups_of vm-a)" = 1
su -s /bin/bash appuser -c "bash $SCRIPT --run" >/tmp/last-output 2>&1
check "normal users are asked to use root" test "$?" = 2

begin "offline"
new_vm vm-a "shut off"
touch "$FAKE/vm-a/uefi"
echo nvram >"$FAKE/vm-a/nvram.bin"
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(first_backup vm-a)
check "powered-off VM copied directly" qemu-img check -q -f qcow2 "$dir/sda.qcow2"
refute "no freeze for a stopped VM" called 'domfsfreeze'
check "UEFI variables saved" test -s "$dir/nvram.fd"
check "manifest says offline" grep -q '^consistency=offline$' "$dir/manifest.txt"
refute "stopped VM is not started" called '^start'

echo "== failures"

begin "freeze-fails"
new_vm vm-a running
touch "$FAKE/freeze-fails"
write_config "$(job nightly backup vm-a)"
now_job nightly
check "reports failure" test "$?" != 0
check "no backup without a freeze" test "$(backups_of vm-a)" = 0
check "error names the guest agent" grep -q 'qemu-guest-agent' <<<"$(state_of nightly vm-a error)"
refute "never copies the live disk unfrozen" called 'domfsthaw'

begin "clone-fails"
new_vm vm-a running
touch "$FAKE/reflink-fails"
mkdir -p "$(vm_dir vm-a)/backup-nightly-20200101-030000"
echo format=2 >"$(vm_dir vm-a)/backup-nightly-20200101-030000/manifest.txt"
write_config "$(job nightly backup vm-a 1 1)"
now_job nightly
check "reports failure" test "$?" != 0
check "VM is thawed when the clone fails" test ! -f "$FAKE/vm-a/frozen"
check "error names btrfs" grep -q 'btrfs' <<<"$(state_of nightly vm-a error)"
check "no partial folder left" test "$(find "$BASE" -name '.partial-*' | wc -l)" = 0
check "retention skipped after a failure" test -d "$(vm_dir vm-a)/backup-nightly-20200101-030000"

begin "interrupted"
new_vm vm-a running
touch "$FAKE/reflink-sleeps"
write_config "$(job nightly backup vm-a)"
"$SCRIPT" --now nightly >/tmp/last-output 2>&1 &
pid=$!
for _ in $(seq 1 50); do [[ -f $FAKE/vm-a/frozen ]] && break; /bin/sleep 0.1; done
check "test reached the frozen state" test -f "$FAKE/vm-a/frozen"
/bin/sleep 0.3
kill -TERM "$pid"
pkill -f '/bin/sleep 20' 2>/dev/null
wait "$pid" 2>/dev/null
check "interrupted run thaws the VM" test ! -f "$FAKE/vm-a/frozen"
check "interrupted run leaves no clone" test "$(find / -xdev -name 'vm-a-sda.*' 2>/dev/null | wc -l)" = 0
check "interrupted run leaves no partial folder" test "$(find "$BASE" -name '.partial-*' | wc -l)" = 0
check "interruption logged" grep -q 'interrupted' "$BASE/ugvm-backup.log"

begin "missing-vm"
new_vm vm-a running
write_config "$(job nightly backup vm-gone)"
now_job nightly
check "missing VM reported as error" test "$(state_of nightly vm-gone error)" = "VM not found"

begin "paused-vm"
new_vm vm-a paused
write_config "$(job nightly backup vm-a)"
now_job nightly
check "paused VM reported" grep -q 'state paused' <<<"$(state_of nightly vm-a error)"
refute "paused VM not frozen" called 'domfsfreeze'

current="no-space"
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  df() { printf "Avail\n1000\n"; }
  du() { printf "5000000000\tx\n"; }
  DISK_PATHS=(/x)
  check_free_space /tmp
  printf "%s|%s" "$?" "$LAST_ERROR"
')
check "too little space stops the backup" grep -q '^1|Not enough space' <<<"$result"

echo "== scheduling"

begin "first-sight"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
tick
check "new job does not run immediately" test "$(backups_of vm-a)" = 0

begin "due"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
tick
sed -i "s/^first=.*/first=$(($(date +%s) - 3 * 86400))/" "$BASE/ugvm-state/nightly.vm-a"
tick
check "runs when a slot has passed" test "$(backups_of vm-a)" = 1
tick
check "does not run twice for one slot" test "$(backups_of vm-a)" = 1

begin "disabled"
new_vm vm-a running
write_config "$(job nightly backup vm-a 0 0 0)"
tick
check "disabled job never runs on schedule" test "$(backups_of vm-a)" = 0
now_job nightly
check "disabled job still runs on request" test "$(backups_of vm-a)" = 1

begin "retry-backoff"
new_vm vm-a running
touch "$FAKE/freeze-fails"
write_config "$(job nightly backup vm-a)"
tick
sed -i "s/^first=.*/first=1000/" "$BASE/ugvm-state/nightly.vm-a"
tick
attempts=$(grep -c domfsfreeze "$FAKE/calls")
tick
check "failed job waits before retrying" test "$(grep -c domfsfreeze "$FAKE/calls")" = "$attempts"

begin "lock"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
(flock -n 9 && /bin/sleep 3) 9>/run/ugvm-backup.lock &
locker=$!
/bin/sleep 0.5
tick
check "second instance exits quietly" test "$?" = 0
now_job nightly
check "manual run refused while locked" test "$?" != 0
check "locked run did nothing" test "$(backups_of vm-a)" = 0
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null
pkill -f '/bin/sleep 3' 2>/dev/null

echo "== slots across daylight saving"
slot_tests=$(TZ=Europe/Berlin bash -c '
  source '"$SOURCE_SCRIPT"'
  noon=$(date -d "2025-03-30 12:00" +%s)
  date -d "@$(latest_slot 24 02:30 "$noon")" "+spring-gap %F %H:%M"
  date -d "@$(latest_slot 24 03:00 "$noon")" "+summer %F %H:%M"
  autumn=$(date -d "2025-10-27 12:00" +%s)
  date -d "@$(latest_slot 24 03:00 "$autumn")" "+winter %F %H:%M"
  early=$(date -d "2025-06-11 02:00" +%s)
  date -d "@$(latest_slot 24 03:00 "$early")" "+before-time %F %H:%M"
  wed=$(date -d "2025-06-11 12:00" +%s)
  date -d "@$(latest_slot 168 03:00 "$wed")" "+weekly %a %H:%M"
  date -d "@$(latest_slot 6 03:00 "$wed")" "+six-hours %H:%M"
')
current="slots"
check "time in DST gap falls back to the offset" grep -q 'spring-gap 2025-03-30 03:30' <<<"$slot_tests"
check "03:00 stays 03:00 in summer time" grep -q 'summer 2025-03-30 03:00' <<<"$slot_tests"
check "03:00 stays 03:00 in winter time" grep -q 'winter 2025-10-27 03:00' <<<"$slot_tests"
check "before today's time uses yesterday" grep -q 'before-time 2025-06-10 03:00' <<<"$slot_tests"
check "weekly jobs land on Monday" grep -q 'weekly Mon 03:00' <<<"$slot_tests"
check "sub-daily intervals align to midnight" grep -q 'six-hours 12:00' <<<"$slot_tests"

echo "== retention"

begin "retention-count"
new_vm vm-a running
d=$(vm_dir vm-a)
for day in 01 02 03 04; do
  mkdir -p "$d/backup-nightly-202001$day-030000"
  echo format=2 >"$d/backup-nightly-202001$day-030000/manifest.txt"
done
mkdir -p "$d/backup-other-20200101-030000" "$d/holiday-photos" "$d/backup-nightly-20200105-030000"
echo format=2 >"$d/backup-other-20200101-030000/manifest.txt"
write_config "$(job nightly backup vm-a 2)"
now_job nightly
check "older backups deleted" test ! -d "$d/backup-nightly-20200103-030000"
check "second newest kept" test -d "$d/backup-nightly-20200104-030000"
check "other job's backups untouched" test -d "$d/backup-other-20200101-030000"
check "foreign folders untouched" test -d "$d/holiday-photos"
check "folders without manifest untouched" test -d "$d/backup-nightly-20200105-030000"

begin "retention-age"
new_vm vm-a running
d=$(vm_dir vm-a)
old=$(date -d '40 days ago' +%Y%m%d)
recent=$(date -d '5 days ago' +%Y%m%d)
for stamp in "$old" "$recent"; do
  mkdir -p "$d/backup-nightly-$stamp-030000"
  echo format=2 >"$d/backup-nightly-$stamp-030000/manifest.txt"
done
write_config "$(job nightly backup vm-a 0 30)"
now_job nightly
check "expired backup deleted" test ! -d "$d/backup-nightly-$old-030000"
check "recent backup kept" test -d "$d/backup-nightly-$recent-030000"

current="retention-logic"
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  now=$((100 * 86400))
  printf "%s\n" "$((1 * 86400)) ancient" | select_expired 1 1 "$now" | wc -l
')
check "the only backup survives any limit" test "$result" = 0
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  printf "1 a\n2 b\n3 c\n" | select_expired 0 0 1000000 | wc -l
')
check "zero limits keep everything" test "$result" = 0
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  now=$((100 * 86400))
  printf "%s\n%s\n%s\n" "$((99 * 86400)) new" "$((98 * 86400)) mid" "$((10 * 86400)) old" | select_expired 5 30 "$now" | tr -d "\n"
')
check "age limit applies inside the count" test "$result" = old
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  now=$((100 * 86400))
  printf "%s\n%s\n%s\n" "$((99 * 86400)) new" "$((98 * 86400)) mid" "$((97 * 86400)) old" | select_expired 2 30 "$now" | tr -d "\n"
')
check "count limit applies inside the age" test "$result" = old

echo "== snapshots"

begin "snapshots"
new_vm vm-a running
mkdir -p "$FAKE/vm-a/snapshots"
printf 'Before the update\n1000\n' >"$FAKE/vm-a/snapshots/vm-a_1000"
for epoch in 2000 3000 4000; do
  printf 'ugvm-backup:job=snap\n%s\n' "$epoch" >"$FAKE/vm-a/snapshots/vm-a_$epoch"
done
write_config "$(job snap snapshot vm-a 2)"
now_job snap
check "manual UGOS snapshot untouched" test -f "$FAKE/vm-a/snapshots/vm-a_1000"
check "old own snapshots removed" test ! -f "$FAKE/vm-a/snapshots/vm-a_2000"
check "newest previous snapshot kept" test -f "$FAKE/vm-a/snapshots/vm-a_4000"
check "new snapshot named like UGOS" test "$(ls "$FAKE/vm-a/snapshots" | grep -cE '^vm-a_[0-9]{10}$')" = 1

begin "snapshot-failure"
new_vm vm-a running
touch "$FAKE/snapshot-fails"
write_config "$(job snap snapshot vm-a 1)"
now_job snap
check "snapshot error reported" grep -q 'internal snapshot not supported' <<<"$(state_of snap vm-a error)"

echo "== OVA on demand"

begin "ova"
new_vm vm-a running
printf 'Name <with> & "quotes"\n' >"$FAKE/vm-a/title"
touch "$FAKE/vm-a/uefi"
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(find "$BASE" -mindepth 2 -maxdepth 2 -type d -name 'backup-*' | head -n 1)
check "a normal backup has no OVA" test ! -e "$dir/vm.ova"
"$SCRIPT" --ova "$dir" >/tmp/last-output 2>&1
check "--ova succeeds" test "$?" = 0
check "OVA created" test -s "$dir/vm.ova"
check "qcow2 kept for restoring" test -s "$dir/sda.qcow2"
check "no partial folder left" test ! -e "$dir/.partial-ova"
check "descriptor is the first file" test "$(tar -tf "$dir/vm.ova" | head -n 1)" = vm.ovf
rm -rf /tmp/ova && mkdir -p /tmp/ova && tar -xf "$dir/vm.ova" -C /tmp/ova
check "disk is stream-optimized VMDK" grep -q 'streamOptimized' <(qemu-img info -f vmdk /tmp/ova/sda.vmdk)
check "OVF is well-formed XML" python3 -c "import xml.dom.minidom as m; m.parse('/tmp/ova/vm.ovf')"
check "VM title is escaped in OVF" grep -q 'Name &lt;with&gt; &amp;' /tmp/ova/vm.ovf
check "UEFI noted in OVF" grep -q 'vmw:value="efi"' /tmp/ova/vm.ovf
check "CPU count from the backup" grep -q '<rasd:VirtualQuantity>2</rasd:VirtualQuantity>' /tmp/ova/vm.ovf
check "RAM from the backup" grep -q '<rasd:VirtualQuantity>2048</rasd:VirtualQuantity>' /tmp/ova/vm.ovf
check "network adapter from the backup" grep -q 'nic0' /tmp/ova/vm.ovf
check "checksums match" bash -c "cd /tmp/ova && sed -E 's/^SHA256\((.*)\)= (.*)/\2  \1/' vm.mf | sha256sum -c --quiet"

begin "ova-after-vm-is-gone"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(first_backup vm-a)
rm -rf "${FAKE:?}/vm-a"
"$SCRIPT" --ova "$dir" >/tmp/last-output 2>&1
check "works when the VM no longer exists" test -s "$dir/vm.ova"

begin "ova-from-incomplete-folder"
mkdir -p "$BASE/x/backup-a-20200101-030000"
"$SCRIPT" --ova "$BASE/x/backup-a-20200101-030000" >/tmp/last-output 2>&1
check "incomplete backup refused" test "$?" = 1
check "refusal explained" grep -q 'not a complete backup' /tmp/last-output

echo "== hostile input"

begin "command-injection"
new_vm vm-a running
cat >"$BASE/config.ini" <<'EOF'
version=2
[job]
id=inj
name=$(touch /tmp/pwned)
type=backup
enabled=1
interval_hours=24
at=03:00
vms=$(touch /tmp/pwned)
keep_count=0
keep_days=0
[job]
id=$(touch /tmp/pwned)
type=backup
enabled=1
interval_hours=24
at=03:00
vms=vm-a
keep_count=0
keep_days=0
[job]
id=inj2
type=backup;touch /tmp/pwned
enabled=1
interval_hours=$(touch /tmp/pwned)
at=`touch /tmp/pwned`
vms=vm-a;touch /tmp/pwned
keep_count=1;touch /tmp/pwned
keep_days=a[$(touch /tmp/pwned)]
EOF
tick
check "no command from config executed" test ! -e /tmp/pwned
"$SCRIPT" --check >/tmp/last-output 2>&1
check "all hostile jobs rejected" test "$(grep -c 'invalid job' /tmp/last-output)" = 3
check "no backup from hostile config" test "$(find "$BASE" -name 'manifest.txt' | wc -l)" = 0
refute "hostile value never reached virsh" called 'touch /tmp/pwned'

begin "broken-config"
new_vm vm-a running
printf 'version=2\n[job]\nthis is no key value\n' >"$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "broken config reported" grep -q 'Invalid line' /tmp/last-output
printf 'version=2\nbogus=1\n' >"$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "unknown key refused" grep -q 'Unknown key' /tmp/last-output
printf 'version=99\n' >"$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "future format refused" grep -q 'Unsupported config version' /tmp/last-output
head -c 70000 /dev/zero | tr '\0' '#' >"$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "oversized config refused" grep -q 'too large' /tmp/last-output

begin "config-symlink"
new_vm vm-a running
printf 'TOP-SECRET-MARKER\n' >/tmp/secret-marker
ln -s /tmp/secret-marker "$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "symlinked config refused" grep -q 'not a regular file' /tmp/last-output
refute "file behind symlink not printed" grep -q 'TOP-SECRET' /tmp/last-output

begin "vm-dir-symlink"
new_vm vm-a running
mkdir -p /tmp/outside
rm -rf /tmp/outside/*
ln -s /tmp/outside "$(vm_dir vm-a)"
write_config "$(job nightly backup vm-a)"
now_job nightly
check "planted VM folder symlink refused" test "$(find /tmp/outside -type f | wc -l)" = 0
check "planted symlink reported" grep -q 'not a regular folder' <<<"$(state_of nightly vm-a error)"

begin "disk-format-probing"
# A guest with a raw disk writes a qcow2 header naming a host file as its
# backing file. Probing the format would make root read that file into the backup.
new_vm vm-a "shut off" raw
printf 'TOP-SECRET-MARKER-ON-HOST\n' >/tmp/secret-marker
qemu-img create -q -f qcow2 -b /tmp/secret-marker -F raw /tmp/evil.qcow2 16M
cp /tmp/evil.qcow2 /volume2/@kvm/vm-a/disk.raw
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(first_backup vm-a)
check "raw disk backed up" test -s "$dir/sda.qcow2"
qemu-img convert -f qcow2 -O raw "$dir/sda.qcow2" /tmp/restored.raw
refute "host file not pulled into the backup" grep -qa 'TOP-SECRET-MARKER-ON-HOST' /tmp/restored.raw

begin "hostile-title"
new_vm vm-a running
printf '../../etc/$(touch /tmp/pwned)\n' >"$FAKE/vm-a/title"
write_config "$(job nightly backup vm-a)"
now_job nightly
check "no command from a VM title executed" test ! -e /tmp/pwned
check "title can't leave the folder" test "$(find "$BASE" -mindepth 1 -maxdepth 1 -type d ! -name ugvm-state | wc -l)" = 1
check "title can't create nested folders" test "$(find "$BASE" -name manifest.txt | awk -F/ '{print NF}')" = 6

echo "== self-update"

new_version() { sed 's/^readonly VERSION=.*/readonly VERSION="'"$1"'"/' "$SOURCE_SCRIPT" >/tmp/remote.sh; }

begin "update"
new_version 9.9.9
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "update succeeds" test "$?" = 0
check "new version installed" test "$("$SCRIPT" --version)" = 9.9.9
check "previous version kept" test -s "$SCRIPT.previous"
check "owner stays the same" test "$(stat -c %U "$SCRIPT")" = appuser
check "script stays executable" test -x "$SCRIPT"
check "no temporary file left" test "$(find "$BASE" -name '.ugvm-update.*' | wc -l)" = 0

begin "update-asks-first"
new_version 9.9.9
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update </dev/null >/tmp/last-output 2>&1
check "nothing installed without confirmation" test "$("$SCRIPT" --version)" != 9.9.9

begin "update-older"
new_version 1.0.0
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "older version refused" test "$("$SCRIPT" --version)" != 1.0.0

begin "update-syntax-error"
new_version 9.9.9
printf 'if then fi (\n' >>/tmp/remote.sh
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "broken download refused" test "$?" = 1
check "script unchanged after broken download" cmp -s "$SOURCE_SCRIPT" "$SCRIPT"

begin "update-not-a-script"
printf '<html>Not found</html>\n' >/tmp/remote.sh
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "web page refused" test "$?" = 1
check "script unchanged after a web page" cmp -s "$SOURCE_SCRIPT" "$SCRIPT"

begin "update-offline"
UGVM_UPDATE_URL=file:///tmp/does-not-exist "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "failed download reported" grep -q 'Download failed' /tmp/last-output

begin "update-during-backup"
new_version 9.9.9
(flock -n 9 && /bin/sleep 3) 9>/run/ugvm-backup.lock &
locker=$!
/bin/sleep 0.5
UGVM_UPDATE_URL=file:///tmp/remote.sh "$SCRIPT" --update --yes >/tmp/last-output 2>&1
check "no update while a backup runs" cmp -s "$SOURCE_SCRIPT" "$SCRIPT"
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null
pkill -f '/bin/sleep 3' 2>/dev/null

echo "== cron"

begin "cron"
echo "0 1 * * * /usr/bin/something" >/tmp/fake-crontab
tui 'cron_install'
check "line added" grep -q "/bin/bash $SCRIPT --run" /tmp/fake-crontab
check "existing entries kept" grep -q something /tmp/fake-crontab
tui 'cron_install'
check "not added twice" test "$(grep -c "$SCRIPT" /tmp/fake-crontab)" = 1
tui 'cron_installed'
check "detected as installed" test "$?" = 0
tui 'cron_remove'
check "line removed" test "$(grep -c "$SCRIPT" /tmp/fake-crontab)" = 0
check "other entries survive removal" grep -q something /tmp/fake-crontab
rm -f /tmp/fake-crontab
tui 'cron_install; cron_remove'
check "removing the only entry succeeds" test "$?" = 0

echo "== terminal interface with scripted answers"

begin "tui-create-job"
new_vm vm-a running
cat >"$ANSWERS" <<'EOF'
0 jobs
0 new
0 Nightly
0 backup
0 vm-a
0 24
0 04:15
0 5
0 14
1
0
0
1
0 exit
EOF
tui_main
check "job written" grep -q '^name=Nightly$' "$BASE/config.ini"
check "VM selection written" grep -q '^vms=vm-a$' "$BASE/config.ini"
check "start time written" grep -q '^at=04:15$' "$BASE/config.ini"
check "keep count written" grep -q '^keep_count=5$' "$BASE/config.ini"
check "keep days written" grep -q '^keep_days=14$' "$BASE/config.ini"
check "config belongs to the folder owner" test "$(stat -c %U "$BASE/config.ini")" = appuser
"$SCRIPT" --check >/tmp/last-output 2>&1
check "written config is valid" grep -q 'valid jobs: 1' /tmp/last-output

begin "tui-all-vms"
new_vm vm-a running
cat >"$ANSWERS" <<'EOF'
0 jobs
0 new
0 All
0 snapshot
0 ALL\nvm-a
0 6
0 3
0 7
1
0
1
0 exit
EOF
tui_main
check "ALL becomes the wildcard" grep -q '^vms=\*$' "$BASE/config.ini"
check "snapshot type written" grep -q '^type=snapshot$' "$BASE/config.ini"
check "pausing is written" grep -q '^enabled=0$' "$BASE/config.ini"

begin "tui-invalid-input"
new_vm vm-a running
cat >"$ANSWERS" <<'EOF'
0 jobs
0 new
0 Bad
0 backup
0 vm-a
0 24
0 99:99
0 5
0 14
1
0
0
1
0 exit
EOF
tui_main
check "invalid time not saved" test ! -e "$BASE/config.ini"
check "user was told why" grep -q 'Invalid time' /tmp/whiptail-calls

begin "tui-cancel"
new_vm vm-a running
printf '0 jobs\n0 new\n0 Half done\n' >"$ANSWERS"
tui_main
check "cancelling saves nothing" test ! -e "$BASE/config.ini"
check "cancelling ends cleanly" test "$?" = 0

begin "tui-delete-job"
new_vm vm-a running
write_config "$(job one backup vm-a)" "$(job two backup vm-a)"
printf '0 jobs\n0 0\n0 delete\n0\n1\n0 exit\n' >"$ANSWERS"
tui_main
refute "deleted job gone" grep -q '^id=one$' "$BASE/config.ini"
check "other job kept" grep -q '^id=two$' "$BASE/config.ini"

begin "tui-backups"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a)"
now_job nightly
dir=$(first_backup vm-a)
printf '0 backups\n0 0\n0 ova\n0\n0\n1\n0 exit\n' >"$ANSWERS"
tui_main
check "OVA created from the backup list" test -s "$dir/vm.ova"
printf '0 backups\n0 0\n0 delete\n0\n1\n0 exit\n' >"$ANSWERS"
tui_main
check "backup deleted from the list" test ! -e "$dir"

begin "tui-startup-offer"
printf '0\n0\n0 exit\n' >"$ANSWERS"
tui_main no-schedule
check "start offers a missing schedule" grep -q 'The schedule is not active' /tmp/whiptail-calls
check "accepting adds the cron line" grep -q "$SCRIPT --run" /tmp/fake-crontab
check "menu then says it is active" grep -q 'Schedule: active' /tmp/whiptail-calls

begin "tui-startup-decline"
printf '1\n0 exit\n' >"$ANSWERS"
tui_main no-schedule
check "declining adds nothing" test ! -e /tmp/fake-crontab
check "menu says it is not active" grep -q 'Schedule: NOT active' /tmp/whiptail-calls

begin "tui-startup-already-active"
printf '0 exit\n' >"$ANSWERS"
tui_main
refute "no question when the schedule is active" grep -q 'The schedule is not active' /tmp/whiptail-calls

begin "tui-cron-menu"
printf '1\n0 cron\n0\n0\n0 exit\n' >"$ANSWERS"
tui_main no-schedule
check "schedule turned on from the menu" grep -q "$SCRIPT --run" /tmp/fake-crontab
printf '0 cron\n0\n0\n0 exit\n' >"$ANSWERS"
tui_main
check "schedule turned off from the menu" test "$(grep -c "$SCRIPT" /tmp/fake-crontab)" = 0

begin "tui-status"
new_vm vm-a running
touch "$FAKE/freeze-fails"
write_config "$(job nightly backup vm-a)"
now_job nightly
printf '1\n0 status\n0\n0 exit\n' >"$ANSWERS"
tui_main no-schedule
check "status shows the VM" grep -q 'Test VM' /tmp/whiptail-calls
check "status shows the problem" grep -q 'qemu-guest-agent' /tmp/whiptail-calls
check "status warns about a missing schedule" grep -q 'NOT ACTIVE' /tmp/whiptail-calls

begin "tui-broken-config"
printf 'garbage\n' >"$BASE/config.ini"
printf '0\n0 jobs\n0\n0 exit\n' >"$ANSWERS"
tui_main
check "broken config is explained" grep -q "config.ini can't be used" /tmp/whiptail-calls
check "broken config is not overwritten" test "$(cat "$BASE/config.ini")" = garbage

begin "check-mode"
new_vm vm-a running
write_config "$(job nightly backup vm-a)"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "--check succeeds" test "$?" = 0
check "--check reports the job" grep -q 'valid jobs: 1' /tmp/last-output
check "--check lists the VM" grep -q 'Test VM' /tmp/last-output
check "--check runs nothing" test "$(backups_of vm-a)" = 0
refute "--check freezes nothing" called 'domfsfreeze'

begin "non-interactive"
"$SCRIPT" </dev/null >/tmp/last-output 2>&1
check "without a terminal it prints help" grep -q -- '--run' /tmp/last-output

echo "== readiness"

begin "readiness-ok"
new_vm vm-a running
"$SCRIPT" --check >/tmp/last-output 2>&1
check "a ready VM is reported as ready" grep -q 'ready for live backups' /tmp/last-output

begin "readiness-not-btrfs"
new_vm vm-a running
touch "$FAKE/not-btrfs"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "a disk outside btrfs is reported" grep -q 'is on ext4. Live backups need btrfs' /tmp/last-output
refute "it is not called ready" grep -q 'ready for live backups' /tmp/last-output

begin "readiness-nocow"
new_vm vm-a running
touch "$FAKE/nocow"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "nodatacow is reported" grep -q 'nodatacow' /tmp/last-output

begin "readiness-agent"
new_vm vm-a running
touch "$FAKE/freeze-fails"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "a silent guest agent is reported" grep -q "guest agent doesn't answer" /tmp/last-output

begin "readiness-powered-off"
new_vm vm-a "shut off"
touch "$FAKE/freeze-fails"
"$SCRIPT" --check >/tmp/last-output 2>&1
refute "a powered-off VM needs no guest agent" grep -q "guest agent" /tmp/last-output

begin "readiness-in-status"
new_vm vm-a running
touch "$FAKE/not-btrfs"
printf '0 status\n0\n0 exit\n' >"$ANSWERS"
tui_main
check "status shows the problem under the VM" grep -q 'Live backups need btrfs' /tmp/whiptail-calls

begin "readiness-when-saving"
new_vm vm-a running
touch "$FAKE/not-btrfs"
printf '0 jobs\n0 new\n0 Nightly\n0 backup\n0 vm-a\n0 24\n0 03:00\n0 3\n0 0\n1\n0\n1\n1\n0 exit\n' >"$ANSWERS"
tui_main
check "saving warns about the VM" grep -q "can't be backed up while they run" /tmp/whiptail-calls
check "going back saves nothing" test ! -e "$BASE/config.ini"
printf '0 jobs\n0 new\n0 Nightly\n0 backup\n0 vm-a\n0 24\n0 03:00\n0 3\n0 0\n1\n0\n0\n0\n1\n0 exit\n' >"$ANSWERS"
tui_main
check "saving anyway keeps the job" grep -q '^name=Nightly$' "$BASE/config.ini"

echo "== compression and priority"

begin "compression"
new_vm vm-a "shut off"
qemu-io -f qcow2 -c 'write -P 0x41 0 4M' /volume2/@kvm/vm-a/disk.qcow2 >/dev/null
write_config "$(job nightly backup vm-a; printf '\ncompress=1')"
now_job nightly
dir=$(first_backup vm-a)
check "backup is valid" qemu-img check -q -f qcow2 "$dir/sda.qcow2"
check "zstd is used" grep -q '"compression-type": "zstd"' <(qemu-img info --output=json "$dir/sda.qcow2")
check "clusters are compressed" grep -q '100.00% compressed' <(qemu-img check -f qcow2 "$dir/sda.qcow2")
check "manifest notes compression" grep -q '^compressed=1$' "$dir/manifest.txt"
check "content is unchanged" qemu-img compare -q -f qcow2 -F qcow2 /volume2/@kvm/vm-a/disk.qcow2 "$dir/sda.qcow2"
"$SCRIPT" --ova "$dir" >/tmp/last-output 2>&1
check "OVA from a compressed backup works" test -s "$dir/vm.ova"

begin "no-compression-by-default"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a)"
now_job nightly
check "manifest says uncompressed" grep -q '^compressed=0$' "$(first_backup vm-a)/manifest.txt"
check "summary mentions nothing" bash -c "source '$SCRIPT'; load_config; job_summary 0 | grep -vq compressed"

begin "compress-value"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a; printf '\ncompress=yes')"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "invalid compress value rejected" grep -q 'Invalid value for compress' /tmp/last-output

current="priority"
check "copies run with the lowest CPU priority" test "$(bash -c "source '$SOURCE_SCRIPT'; heavy nice")" = 19
check "copies run with the lowest disk priority" grep -q 'best-effort: prio 7' <(bash -c "source '$SOURCE_SCRIPT'; heavy ionice")

echo "== storage"

begin "storage"
new_vm vm-a "shut off"
write_config "$(job nightly backup vm-a)"
now_job nightly
"$SCRIPT" --check >/tmp/last-output 2>&1
check "free space shown" grep -q 'Free:' /tmp/last-output
check "space used by backups shown" grep -q 'Used by backups:' /tmp/last-output
check "space per VM shown" grep -q 'Test_VM-vm-a:' /tmp/last-output
check "room for more backups estimated" grep -q 'Room for about' /tmp/last-output
printf '0 status\n0\n0 exit\n' >"$ANSWERS"
tui_main
check "status shows storage" grep -q 'Used by backups' /tmp/whiptail-calls

begin "storage-running-out"
mkdir -p "$BASE/x/backup-a-20200101-030000"
printf 'created=1577847600\nsize=900000000000000\n' >"$BASE/x/backup-a-20200101-030000/manifest.txt"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "running out of space is reported" grep -q 'Not enough free space for the next backup' /tmp/last-output

echo "== restore"

# restore_setup <state>: makes a backup, then changes the disk and UEFI variables.
restore_setup() {
  new_vm vm-a "$1"
  touch "$FAKE/vm-a/uefi"
  echo old-nvram >"$FAKE/vm-a/nvram.bin"
  qemu-io -f qcow2 -c 'write -P 0x41 0 1M' /volume2/@kvm/vm-a/disk.qcow2 >/dev/null
  write_config "$(job nightly backup vm-a)"
  now_job nightly
  dir=$(first_backup vm-a)
  qemu-io -f qcow2 -c 'write -P 0x42 0 1M' /volume2/@kvm/vm-a/disk.qcow2 >/dev/null
  echo new-nvram >"$FAKE/vm-a/nvram.bin"
  cp /volume2/@kvm/vm-a/disk.qcow2 /tmp/changed.qcow2
  rm -f "$FAKE/calls"
}
disk_is_backup() { qemu-img compare -q -f qcow2 -F qcow2 "$dir/sda.qcow2" /volume2/@kvm/vm-a/disk.qcow2; }
disk_unchanged() { qemu-img compare -q -f qcow2 -F qcow2 /tmp/changed.qcow2 /volume2/@kvm/vm-a/disk.qcow2; }
kept_disks() { find /volume2/@kvm/vm-a -name 'disk.qcow2.before-restore-*' | wc -l; }

begin "restore-running"
restore_setup running
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "restore succeeds" test "$?" = 0
check "disk has the backup's content" disk_is_backup
check "running VM was shut down" called '^shutdown'
check "VM runs again afterwards" test "$(cat "$FAKE/vm-a/state")" = running
check "previous disk is kept" test "$(kept_disks)" = 1
check "kept disk has the newer content" qemu-img compare -q -f qcow2 -F qcow2 /tmp/changed.qcow2 /volume2/@kvm/vm-a/disk.qcow2.before-restore-*
check "UEFI variables restored" test "$(cat "$FAKE/vm-a/nvram.bin")" = old-nvram
check "previous UEFI variables kept" test "$(cat "$FAKE"/vm-a/nvram.bin.before-restore-*)" = new-nvram
check "kept files are listed" grep -q 'before-restore' /tmp/last-output
check "restore logged" grep -q 'Restored VM vm-a' "$BASE/ugvm-backup.log"
refute "VM never forced off" called '^destroy'

begin "restore-stopped"
restore_setup "shut off"
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "disk has the backup's content" disk_is_backup
refute "stopped VM is not shut down" called '^shutdown'
refute "stopped VM stays off" called '^start'

begin "restore-asks-first"
restore_setup running
"$SCRIPT" --restore "$dir" </dev/null >/tmp/last-output 2>&1
check "refuses without confirmation" test "$?" = 1
check "disk unchanged without confirmation" disk_unchanged
refute "VM untouched without confirmation" called '^shutdown'

begin "restore-snapshots"
restore_setup running
mkdir -p "$FAKE/vm-a/snapshots"
printf 'manual\n1000\n' >"$FAKE/vm-a/snapshots/vm-a_1000"
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "refused while the VM has snapshots" grep -q 'snapshot' /tmp/last-output
check "disk unchanged" disk_unchanged
refute "VM not shut down" called '^shutdown'

begin "restore-vm-gone"
restore_setup "shut off"
rm -rf "${FAKE:?}/vm-a"
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "missing VM points to the OVA" grep -q 'no longer exists. Create an OVA' /tmp/last-output

begin "restore-damaged-backup"
restore_setup running
printf 'garbage garbage garbage' | dd of="$dir/sda.qcow2" bs=1 conv=notrunc status=none
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "damaged backup refused" grep -q 'is damaged' /tmp/last-output
check "disk unchanged" disk_unchanged
refute "VM not shut down for a damaged backup" called '^shutdown'

begin "restore-mismatch"
restore_setup "shut off"
cp "$dir/sda.qcow2" "$dir/sdb.qcow2"
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "backup with other disks refused" grep -q "don't match" /tmp/last-output
check "disk unchanged" disk_unchanged

begin "restore-shutdown-timeout"
restore_setup running
touch "$FAKE/refuses-shutdown"
UGVM_SHUTDOWN_TIMEOUT=2 "$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
check "timeout reported" grep -q 'did not shut down' /tmp/last-output
check "disk unchanged" disk_unchanged
check "nothing moved aside" test "$(kept_disks)" = 0
refute "VM never forced off" called '^destroy'

begin "restore-copy-fails"
restore_setup running
cat >/usr/sbin/qemu-img <<'EOF'
#!/bin/sh
[ "$1" = convert ] && { echo "qemu-img: simulated failure" >&2; exit 1; }
exec /usr/bin/qemu-img "$@"
EOF
chmod 0755 /usr/sbin/qemu-img
"$SCRIPT" --restore "$dir" --yes >/tmp/last-output 2>&1
rm -f /usr/sbin/qemu-img
check "failure reported" grep -q 'previous disks are back in place' /tmp/last-output
check "previous disk is back" disk_unchanged
check "nothing left aside" test "$(kept_disks)" = 0
check "VM runs again after the failure" test "$(cat "$FAKE/vm-a/state")" = running

begin "restore-from-menu"
restore_setup running
schedule_on
printf '0 backups\n0 0\n0 restore\n0\n0\n1\n0 exit\n' >"$ANSWERS"
tui 'tui_main'
check "restore from the backup list works" disk_is_backup
check "menu asked before restoring" grep -q 'will be shut down, restored and started again' /tmp/whiptail-calls
check "menu lists the kept files" grep -q 'before-restore' /tmp/whiptail-calls

begin "restore-cancelled-in-menu"
restore_setup running
schedule_on
printf '0 backups\n0 0\n0 restore\n1\n1\n0 exit\n' >"$ANSWERS"
tui 'tui_main'
check "cancelling keeps the disk" disk_unchanged
refute "cancelling keeps the VM running" called '^shutdown'

echo "== real whiptail in a real terminal"

rm -f /usr/sbin/whiptail
begin "real-terminal"
new_vm vm-a running
schedule_on
python3 /src/tests/terminal-test.py "$SCRIPT" >/tmp/tty.out 2>&1
check "drives the real interface" test "$?" = 0
check "main menu appears despite an unknown terminal type" grep -q 'MAIN-MENU-OK' /tmp/tty.out
check "overview opens" grep -q 'STATUS-OK' /tmp/tty.out
check "job created through real dialogs" grep -q '^name=Nightly$' "$BASE/config.ini"
check "default VM selection is parsed" grep -q '^vms=\*$' "$BASE/config.ini"
"$SCRIPT" --check >/tmp/last-output 2>&1
check "that job is valid" grep -q 'valid jobs: 1' /tmp/last-output
grep -q '^EXIT 0$' /tmp/tty.out || cat /tmp/tty.out

begin "real-terminal-startup"
python3 /src/tests/terminal-test.py "$SCRIPT" --startup >/tmp/tty.out 2>&1
check "startup offer works in a real terminal" test "$?" = 0
check "accepting it adds the cron line" grep -q "$SCRIPT --run" /tmp/fake-crontab
grep -q '^EXIT 0$' /tmp/tty.out || cat /tmp/tty.out

begin "real-terminal-long-text"
schedule_on
for number in $(seq 10 45); do
  new_vm "vm-$number" running
done
python3 /src/tests/terminal-test.py "$SCRIPT" --scrolling >/tmp/tty.out 2>&1
check "long text can be closed" test "$?" = 0
check "scrolling window says how to close it" grep -q 'SCROLL-HINT-OK' /tmp/tty.out
check "Tab and Enter close it" grep -q 'SCROLL-CLOSE-OK' /tmp/tty.out
grep -q '^EXIT 0$' /tmp/tty.out || cat /tmp/tty.out

printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
