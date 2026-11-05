#!/usr/bin/env bash
#
# Tests for ugvm-backup. Runs as root inside a disposable Debian 12 container
# (see tests/run-in-docker.sh), because it installs a stub virsh into /usr/bin
# and writes to /volume1. Never run this on a real system.

set -u

if [[ ! -f /.dockerenv ]]; then
  echo "refusing to run outside a container" >&2
  exit 2
fi

SOURCE_SCRIPT=/src/app/rootfs_common/libexec/ugvm-backup.sh
SCRIPT=/usr/local/sbin/ugvm-backup
STATE=/var/lib/ugvm-backup
FAKE=/tmp/fakevirt
CONFIG=/volume1/cfg
TARGET=/volume1/backups

install -o root -g root -m 0755 "$SOURCE_SCRIPT" "$SCRIPT"
install -o root -g root -m 0755 /src/tests/script/stub-virsh /usr/bin/virsh
id -u appuser >/dev/null 2>&1 || useradd -M appuser

passed=0
failed=0
current=""

begin() {
  current=$1
  rm -rf "$FAKE" "$STATE" /volume1 /tmp/pwned /tmp/secret-marker
  mkdir -p "$FAKE" "$CONFIG" "$TARGET" /volume1/@kvm
  chown appuser "$CONFIG"
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
  mkdir -p "$FAKE/$vm" "/volume1/@kvm/$vm"
  echo "$state" >"$FAKE/$vm/state"
  echo "Test VM $vm" >"$FAKE/$vm/title"
  disk="/volume1/@kvm/$vm/disk.$format"
  qemu-img create -q -f "$format" "$disk" 16M
  printf 'vda %s %s\n' "$format" "$disk" >"$FAKE/$vm/disks"
}

# write_config <job body...>: each argument is a full job section as lines
write_config() {
  {
    echo "version=1"
    local section
    for section in "$@"; do
      printf '[job]\n%s\n' "$section"
    done
  } >"$CONFIG/config.ini"
}

job() { # job <id> <type> <vms> [keep_count] [keep_days] [running_vm]
  printf 'id=%s\ntype=%s\nenabled=1\ninterval_hours=24\nat=03:00\nvms=%s\ntarget=%s\nkeep_count=%s\nkeep_days=%s\nrunning_vm=%s' \
    "$1" "$2" "$3" "$TARGET" "${4:-0}" "${5:-0}" "${6:-live}"
}

request() {
  mkdir -p "$CONFIG/requests"
  touch "$CONFIG/requests/$1"
}

tick() { "$SCRIPT" --config "$CONFIG" >/tmp/last-output 2>&1; }

status_field() { python3 -c "
import json,sys
d=json.load(open('$CONFIG/status.json'))
print(eval(sys.argv[1],{'d':d}))" "$1"; }

backups_of() { find "$TARGET/$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }
called() { grep -qE -- "$1" "$FAKE/calls"; }

echo "== scheduling"

begin "first-sight"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
tick
check "new job does not run immediately" test "$(backups_of vm-a)" = 0
refute "no disk operation on first sight" called 'backup-begin'
check "status published" test -f "$CONFIG/status.json"

begin "due"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
tick
sed -i "s/^first=.*/first=$(($(date +%s) - 3 * 86400))/" "$STATE/jobs/nightly.vm-a"
tick
check "runs when a slot has passed" test "$(backups_of vm-a)" = 1
tick
check "does not run twice for one slot" test "$(backups_of vm-a)" = 1

begin "disabled"
new_vm vm-a running
write_config "$(job nightly file vm-a | sed 's/^enabled=1/enabled=0/')"
tick
sed -i "s/^first=.*/first=1000/" "$STATE/jobs/nightly.vm-a" 2>/dev/null
tick
check "disabled job never runs on schedule" test "$(backups_of vm-a)" = 0
request nightly
tick
check "disabled job still runs on request" test "$(backups_of vm-a)" = 1

begin "retry-backoff"
new_vm vm-a running
touch "$FAKE/no-live-backup"
write_config "$(job nightly file vm-a)"
tick
sed -i "s/^first=.*/first=1000/" "$STATE/jobs/nightly.vm-a"
tick
attempts=$(grep -c backup-begin "$FAKE/calls")
tick
check "failed job waits before retrying" test "$(grep -c backup-begin "$FAKE/calls")" = "$attempts"

begin "lock"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
request nightly
mkdir -p "$STATE"
chmod 700 "$STATE"
(flock -n 9 && /bin/sleep 3) 9>"$STATE/lock" &
locker=$!
/bin/sleep 0.5
tick
check "second instance exits quietly" test "$?" = 0
check "second instance did not run the job" test "$(backups_of vm-a)" = 0
kill "$locker" 2>/dev/null
wait "$locker" 2>/dev/null

echo "== slots across daylight saving"
slot_tests=$(TZ=Europe/Berlin bash -c '
  source '"$SOURCE_SCRIPT"'
  # 2025-03-30 is the spring change in Berlin, 02:30 does not exist that day.
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

echo "== backups"

begin "live"
new_vm vm-a running
touch "$FAKE/vm-a/agent"
write_config "$(job nightly file vm-a)"
request nightly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "backup folder has the final name" grep -qE '/file-nightly-[0-9]{8}-[0-9]{6}$' <<<"$dir"
check "disk is a valid qcow2" qemu-img check -q -f qcow2 "$dir/vda.qcow2"
check "domain definition saved" test -s "$dir/domain.xml"
check "manifest records consistency" grep -q '^consistency=filesystem$' "$dir/manifest.txt"
check "guest was frozen" test -f "$FAKE/vm-a/was-frozen"
check "guest was thawed" test -f "$FAKE/vm-a/was-thawed"
check "no partial folder left" test "$(find "$TARGET" -name '.partial-*' | wc -l)" = 0
check "VM stays untouched" test "$(cat "$FAKE/vm-a/state")" = running
refute "live backup does not shut down" test -f "$FAKE/vm-a/was-shutdown"
check "status lists the backup" test "$(status_field 'len(d["backups"])')" = 1
check "status shows success" test "$(status_field 'd["jobs"][0]["vms"][0]["result"]')" = ok
check "status is idle afterwards" test "$(status_field 'd["state"]')" = idle
check "status readable by app user only" test "$(stat -c '%U %a' "$CONFIG/status.json")" = "appuser 640"

begin "no-agent"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
request nightly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "without agent marked crash-consistent" grep -q '^consistency=crash$' "$dir/manifest.txt"
refute "no freeze without agent" test -f "$FAKE/vm-a/was-frozen"

begin "offline"
new_vm vm-a "shut off"
touch "$FAKE/vm-a/uefi"
echo nvram >"$FAKE/vm-a/nvram.bin"
write_config "$(job nightly file vm-a)"
request nightly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "powered-off VM copied directly" qemu-img check -q -f qcow2 "$dir/vda.qcow2"
refute "no live backup for a stopped VM" called 'backup-begin'
check "UEFI variables saved" test -s "$dir/nvram.fd"
check "manifest says offline" grep -q '^consistency=offline$' "$dir/manifest.txt"
refute "stopped VM is not started" test -f "$FAKE/vm-a/was-started"

begin "ownership"
new_vm vm-a "shut off"
chown appuser "$TARGET"
write_config "$(job nightly file vm-a)"
request nightly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "backup belongs to the folder owner" test "$(stat -c %U "$dir/vda.qcow2")" = appuser
check "backup files not world-readable" test "$(stat -c %a "$dir/vda.qcow2")" = 640
check "backup folder not world-readable" test "$(stat -c %a "$dir")" = 750

begin "ova"
new_vm vm-a running
printf 'Name <with> & "quotes"\n' >"$FAKE/vm-a/title"
touch "$FAKE/vm-a/uefi"
write_config "$(job weekly ova vm-a)"
request weekly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "OVA created" test -s "$dir/vm.ova"
check "descriptor is the first file" test "$(tar -tf "$dir/vm.ova" | head -n 1)" = vm.ovf
check "OVA contains stream-optimized disk" tar -tf "$dir/vm.ova" vda.vmdk
mkdir -p /tmp/ova && rm -rf /tmp/ova/* && tar -xf "$dir/vm.ova" -C /tmp/ova
check "disk is stream-optimized VMDK" grep -q 'subformat: streamOptimized\|create type: streamOptimized' <(qemu-img info -f vmdk /tmp/ova/vda.vmdk)
check "OVF is well-formed XML" python3 -c "import xml.dom.minidom as m; m.parse('/tmp/ova/vm.ovf')"
check "VM title is escaped in OVF" grep -q 'Name &lt;with&gt; &amp;' /tmp/ova/vm.ovf
check "UEFI noted in OVF" grep -q 'vmw:value="efi"' /tmp/ova/vm.ovf
check "checksums match" bash -c "cd /tmp/ova && sed -E 's/^SHA256\((.*)\)= (.*)/\2  \1/' vm.mf | sha256sum -c --quiet"
check "qcow2 removed after packing" test "$(find "$dir" -name '*.qcow2' | wc -l)" = 0

begin "skip-mode"
new_vm vm-a running
write_config "$(job nightly file vm-a 0 0 skip)"
request nightly
tick
check "running VM skipped" test "$(backups_of vm-a)" = 0
check "skip is recorded" test "$(status_field 'd["jobs"][0]["vms"][0]["result"]')" = skipped

begin "shutdown-mode"
new_vm vm-a running
write_config "$(job nightly file vm-a 0 0 shutdown)"
request nightly
tick
check "VM was shut down" test -f "$FAKE/vm-a/was-shutdown"
check "VM runs again afterwards" test "$(cat "$FAKE/vm-a/state")" = running
check "backup exists" test "$(backups_of vm-a)" = 1

begin "shutdown-restart-on-failure"
new_vm vm-a running
write_config "$(job nightly file vm-a 0 0 shutdown)"
request nightly
# Breaking the disk makes the copy fail while the VM is down.
sed -i 's#disk.qcow2#missing.qcow2#' "$FAKE/vm-a/disks"
tick
check "VM is restarted even when the copy fails" test "$(cat "$FAKE/vm-a/state")" = running
check "failure reported" test "$(status_field 'd["jobs"][0]["vms"][0]["result"]')" = error
check "no partial folder left" test "$(find "$TARGET" -name '.partial-*' | wc -l)" = 0

echo "== failures keep existing backups"

begin "failed-live"
new_vm vm-a running
touch "$FAKE/backup-job-fails"
mkdir -p "$TARGET/vm-a/file-nightly-20200101-030000"
echo format=1 >"$TARGET/vm-a/file-nightly-20200101-030000/manifest.txt"
mkdir -p "$TARGET/vm-a/file-nightly-20200102-030000"
echo format=1 >"$TARGET/vm-a/file-nightly-20200102-030000/manifest.txt"
write_config "$(job nightly file vm-a 1 1)"
request nightly
tick
check "aborted copy is never promoted" test "$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | grep -c 'file-nightly-20200')" = 2
check "no new backup from a failed job" test "$(backups_of vm-a)" = 2
check "retention skipped after failure" test -d "$TARGET/vm-a/file-nightly-20200101-030000"
check "error reported" grep -q 'did not finish successfully' <(status_field 'd["jobs"][0]["vms"][0]["error"]')

begin "missing-vm"
new_vm vm-a running
write_config "$(job nightly file vm-gone)"
request nightly
tick
check "missing VM reported as error" grep -q 'not found' <(status_field 'd["jobs"][0]["vms"][0]["error"]')

begin "no-space"
new_vm vm-a running
# A big allocated disk against a tiny tmpfs would need privileges, so the check
# is exercised directly with a fake df answer.
mkdir -p /tmp/fakedf
result=$(bash -c '
  source '"$SOURCE_SCRIPT"'
  df() { printf "Avail\n1000\n"; }
  du() { printf "5000000000\tx\n"; }
  DISK_PATHS=(/x)
  check_free_space /volume1 1
  printf "%s|%s" "$?" "$LAST_ERROR"
')
check "too little space stops the backup" grep -q '^1|Not enough space' <<<"$result"

echo "== retention"

begin "retention-count"
new_vm vm-a running
for day in 01 02 03 04; do
  mkdir -p "$TARGET/vm-a/file-nightly-202001$day-030000"
  echo format=1 >"$TARGET/vm-a/file-nightly-202001$day-030000/manifest.txt"
done
mkdir -p "$TARGET/vm-a/file-other-20200101-030000" "$TARGET/vm-a/holiday-photos" "$TARGET/vm-a/file-nightly-20200105-030000"
echo format=1 >"$TARGET/vm-a/file-other-20200101-030000/manifest.txt"
write_config "$(job nightly file vm-a 2)"
request nightly
tick
check "keeps the newest backups within the count" test "$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d -name 'file-nightly-*' -newer "$CONFIG/config.ini" | wc -l)" -ge 1
check "older backups deleted" test ! -d "$TARGET/vm-a/file-nightly-20200103-030000"
check "second newest kept" test -d "$TARGET/vm-a/file-nightly-20200104-030000"
check "other job's backups untouched" test -d "$TARGET/vm-a/file-other-20200101-030000"
check "foreign folders untouched" test -d "$TARGET/vm-a/holiday-photos"
check "folders without manifest untouched" test -d "$TARGET/vm-a/file-nightly-20200105-030000"

begin "retention-age"
new_vm vm-a running
old=$(date -d '40 days ago' +%Y%m%d)
recent=$(date -d '5 days ago' +%Y%m%d)
for stamp in "$old" "$recent"; do
  mkdir -p "$TARGET/vm-a/file-nightly-$stamp-030000"
  echo format=1 >"$TARGET/vm-a/file-nightly-$stamp-030000/manifest.txt"
done
write_config "$(job nightly file vm-a 0 30)"
request nightly
tick
check "expired backup deleted" test ! -d "$TARGET/vm-a/file-nightly-$old-030000"
check "recent backup kept" test -d "$TARGET/vm-a/file-nightly-$recent-030000"

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
printf 'Vor dem Update\n1000\n' >"$FAKE/vm-a/snapshots/vm-a_1000"
for epoch in 2000 3000 4000; do
  printf 'ugvm-backup:job=snap\n%s\n' "$epoch" >"$FAKE/vm-a/snapshots/vm-a_$epoch"
done
write_config "$(job snap snapshot vm-a 2)"
request snap
tick
check "manual UGOS snapshot untouched" test -f "$FAKE/vm-a/snapshots/vm-a_1000"
check "old own snapshots removed" test ! -f "$FAKE/vm-a/snapshots/vm-a_2000"
check "older own snapshot removed" test ! -f "$FAKE/vm-a/snapshots/vm-a_3000"
check "newest previous snapshot kept" test -f "$FAKE/vm-a/snapshots/vm-a_4000"
check "new snapshot named like UGOS" test "$(ls "$FAKE/vm-a/snapshots" | grep -cE '^vm-a_[0-9]{10}$')" = 1
check "status lists own snapshots only" test "$(status_field 'len(d["snapshots"])')" = 2

begin "snapshot-failure"
new_vm vm-a running
touch "$FAKE/snapshot-fails"
write_config "$(job snap snapshot vm-a 1)"
request snap
tick
check "snapshot error reported" grep -q 'internal snapshot not supported' <(status_field 'd["jobs"][0]["vms"][0]["error"]')

echo "== attacks through config and shared folders"

begin "target-symlink"
new_vm vm-a running
mkdir -p /tmp/outside
rm -rf /tmp/outside/*
ln -s /tmp/outside "$TARGET/link"
write_config "$(job nightly file vm-a | sed "s#^target=.*#target=$TARGET/link#")"
request nightly
tick
check "symlink target leaving the volume refused" test "$(find /tmp/outside -type f | wc -l)" = 0
check "rejected job reported" grep -q 'Target folder' <(status_field 'd["job_errors"]')

begin "target-system-folder"
new_vm vm-a running
write_config "$(job nightly file vm-a | sed 's#^target=.*#target=/volume1/@kvm#')"
request nightly
tick
check "@kvm refused as target" test ! -e /volume1/@kvm/vm-a/file-nightly

begin "target-symlink-to-system-folder"
new_vm vm-a running
ln -s /volume1/@kvm "$TARGET/link"
write_config "$(job nightly file vm-a | sed "s#^target=.*#target=$TARGET/link#")"
request nightly
tick
check "symlink to @kvm refused" test "$(find /volume1/@kvm -name 'manifest.txt' | wc -l)" = 0

for bad in '/etc' '/volume1/../etc' '/volume1/backups/../../etc' '/tmp' 'relative/path' '/volume1' ''; do
  begin "target-value"
  new_vm vm-a running
  write_config "$(job nightly file vm-a | sed "s#^target=.*#target=$bad#")"
  request nightly
  tick
  check "target '$bad' refused" test "$(status_field 'len(d["job_errors"])')" = 1
done

begin "vm-dir-symlink"
new_vm vm-a running
mkdir -p /tmp/outside
rm -rf /tmp/outside/*
ln -s /tmp/outside "$TARGET/vm-a"
write_config "$(job nightly file vm-a)"
request nightly
tick
check "planted VM folder symlink refused" test "$(find /tmp/outside -type f | wc -l)" = 0
check "planted symlink reported" grep -q 'not a regular folder' <(status_field 'd["jobs"][0]["vms"][0]["error"]')

begin "command-injection"
new_vm vm-a running
cat >"$CONFIG/config.ini" <<'EOF'
version=1
[job]
id=inj
name=$(touch /tmp/pwned)
type=file
enabled=1
interval_hours=24
at=03:00
vms=$(touch /tmp/pwned)
target=/volume1/backups
keep_count=0
keep_days=0
running_vm=live
[job]
id=$(touch /tmp/pwned)
type=file
enabled=1
interval_hours=24
at=03:00
vms=vm-a
target=/volume1/backups
keep_count=0
keep_days=0
running_vm=live
[job]
id=inj2
type=file;touch /tmp/pwned
enabled=1
interval_hours=$(touch /tmp/pwned)
at=`touch /tmp/pwned`
vms=vm-a;touch /tmp/pwned
target=/volume1/backups/$(touch /tmp/pwned)
keep_count=1;touch /tmp/pwned
keep_days=a[$(touch /tmp/pwned)]
running_vm=live
EOF
touch /tmp/marker
mkdir -p "$CONFIG/requests"
touch "$CONFIG/requests/inj" "$CONFIG/requests/inj2"
touch "$CONFIG/requests/\$(touch \$HOME\/x)" 2>/dev/null
tick
check "no command from config executed" test ! -e /tmp/pwned
check "all hostile jobs rejected" test "$(status_field 'len(d["job_errors"])')" = 3
check "status stays valid JSON" python3 -m json.tool "$CONFIG/status.json" /dev/null
check "no backup from hostile config" test "$(find "$TARGET" -type f | wc -l)" = 0
refute "hostile VM id never reached virsh" called 'touch /tmp/pwned'

begin "arithmetic-injection"
new_vm vm-a running
write_config "$(job nightly file vm-a | sed 's/^keep_count=.*/keep_count=x[$(touch \/tmp\/pwned)]/')"
request nightly
tick
check "arithmetic expansion attack blocked" test ! -e /tmp/pwned

begin "broken-config"
new_vm vm-a running
printf 'version=1\n[job]\nthis is no key value\n' >"$CONFIG/config.ini"
request nightly
tick
check "broken config reported" grep -q 'Invalid line' <(status_field 'd["config_error"]')
printf 'version=1\nbogus=1\n' >"$CONFIG/config.ini"
tick
check "unknown key refused" grep -q 'Unknown key' <(status_field 'd["config_error"]')
printf 'version=99\n' >"$CONFIG/config.ini"
tick
check "future format refused" grep -q 'Unsupported config version' <(status_field 'd["config_error"]')
head -c 70000 /dev/zero | tr '\0' '#' >"$CONFIG/config.ini"
tick
check "oversized config refused" grep -q 'too large' <(status_field 'd["config_error"]')

begin "config-symlink"
new_vm vm-a running
printf 'TOP-SECRET-MARKER\n' >/tmp/secret-marker
ln -s /tmp/secret-marker "$CONFIG/config.ini"
tick
check "symlinked config refused" grep -q 'not a regular file' <(status_field 'd["config_error"]')
refute "file behind symlink not leaked into status" grep -q 'TOP-SECRET' "$CONFIG/status.json"

begin "config-line-not-leaked"
new_vm vm-a running
printf 'TOP-SECRET-MARKER\n' >"$CONFIG/config.ini"
tick
refute "invalid lines are not echoed to status" grep -q 'TOP-SECRET' "$CONFIG/status.json"
refute "invalid lines are not logged" grep -q 'TOP-SECRET' "$STATE/log"

begin "status-symlink"
new_vm vm-a running
printf 'do not touch\n' >/tmp/victim
ln -s /tmp/victim "$CONFIG/status.json"
write_config "$(job nightly file vm-a)"
tick
check "symlink target not overwritten" test "$(cat /tmp/victim)" = "do not touch"
refute "planted status symlink replaced" test -L "$CONFIG/status.json"

begin "disk-format-probing"
# A guest with a raw disk writes a qcow2 header naming a host file as its
# backing file. Probing the format would make root read that file into the backup.
new_vm vm-a "shut off" raw
printf 'TOP-SECRET-MARKER-ON-HOST\n' >/tmp/secret-marker
qemu-img create -q -f qcow2 -b /tmp/secret-marker -F raw /tmp/evil.qcow2 16M
cp /tmp/evil.qcow2 /volume1/@kvm/vm-a/disk.raw
write_config "$(job nightly file vm-a)"
request nightly
tick
dir=$(find "$TARGET/vm-a" -mindepth 1 -maxdepth 1 -type d | head -n 1)
check "raw disk backed up" test -s "$dir/vda.qcow2"
qemu-img convert -f qcow2 -O raw "$dir/vda.qcow2" /tmp/restored.raw
refute "host file not pulled into the backup" grep -qa 'TOP-SECRET-MARKER-ON-HOST' /tmp/restored.raw

begin "manifest-injection"
new_vm vm-a running
hostile="$TARGET/vm-a/file-nightly-20200101-030000"
mkdir -p "$hostile"
printf 'created=1","x":"y\nsize=$(touch /tmp/pwned)\nconsistency="><img>\n' >"$hostile/manifest.txt"
write_config "$(job nightly file vm-a)"
tick
check "hostile manifest keeps status valid" python3 -m json.tool "$CONFIG/status.json" /dev/null
check "hostile manifest values dropped" test "$(status_field 'd["backups"][0]["created"]')" = 0
check "no command from manifest executed" test ! -e /tmp/pwned

begin "hostile-vm-title"
new_vm vm-a running
printf '"},{"evil":1 <script>\\n$(touch /tmp/pwned)\n' >"$FAKE/vm-a/title"
write_config "$(job nightly file vm-a)"
tick
check "hostile title keeps status valid" python3 -m json.tool "$CONFIG/status.json" /dev/null
check "title preserved as plain data" grep -q 'evil' <(status_field 'd["vms"][0]["title"]')
check "no command from title executed" test ! -e /tmp/pwned

begin "request-symlink"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
printf 'keep me\n' >/tmp/victim
mkdir -p "$CONFIG/requests"
ln -s /tmp/victim "$CONFIG/requests/nightly"
tick
check "symlinked request ignored" test "$(backups_of vm-a)" = 0
check "file behind request symlink kept" test "$(cat /tmp/victim)" = "keep me"

echo "== script self-protection"

begin "self-protection"
mkdir -p /tmp/insecure
cp "$SOURCE_SCRIPT" /tmp/insecure/ugvm
chown root:root /tmp/insecure/ugvm
chmod 0755 /tmp/insecure/ugvm
chmod 0777 /tmp/insecure
/tmp/insecure/ugvm --config "$CONFIG" >/tmp/out 2>&1
check "refuses a world-writable folder" test "$?" = 2
chmod 0755 /tmp/insecure
chmod 0777 /tmp/insecure/ugvm
/tmp/insecure/ugvm --config "$CONFIG" >/tmp/out 2>&1
check "refuses a world-writable script" test "$?" = 2
chmod 0755 /tmp/insecure/ugvm
chown appuser /tmp/insecure/ugvm
/tmp/insecure/ugvm --config "$CONFIG" >/tmp/out 2>&1
check "refuses a script not owned by root" test "$?" = 2
chown root:root /tmp/insecure/ugvm
su -s /bin/bash appuser -c "$SCRIPT --config $CONFIG" >/tmp/out 2>&1
check "refuses to run without root" test "$?" = 2

for bad in /etc /volume1/@kvm /tmp; do
  "$SCRIPT" --config "$bad" >/tmp/out 2>&1
  check "refuses config folder $bad" test "$?" = 2
done

begin "check-mode"
new_vm vm-a running
write_config "$(job nightly file vm-a)"
"$SCRIPT" --config "$CONFIG" --check >/tmp/out 2>&1
check "--check succeeds" test "$?" = 0
check "--check reports the job" grep -q 'valid jobs: 1' /tmp/out
check "--check runs nothing" test "$(backups_of vm-a)" = 0

printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
