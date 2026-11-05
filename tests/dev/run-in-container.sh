#!/usr/bin/env bash
# Development only, runs in a throwaway container. Starts the real backend and
# the real backup script against stubbed VMs and seeded backup history.
set -eu
[[ -f /.dockerenv ]] || { echo "refusing to run outside a container" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends qemu-utils tzdata >/dev/null 2>&1

install -o root -g root -m 0755 /src/app/rootfs_common/libexec/ugvm-backup.sh /usr/local/sbin/ugvm-backup
install -o root -g root -m 0755 /src/tests/script/stub-virsh /usr/bin/virsh

FAKE=/tmp/fakevirt
SHARED=/app/shared
mkdir -p "$FAKE" "$SHARED" /app/data /app/install /app/log \
  /volume1/backup/vm /volume1/backup/archive/2026 /volume1/vm-archive /volume1/@kvm /home/dev/docs

ln -sfn /volume1/backup "$SHARED/backup"
ln -sfn /volume1/vm-archive "$SHARED/vm-archive"
ln -sfn /home/dev/docs "$SHARED/personal"

new_vm() { # id title state [uefi] [agent]
  local vm=$1
  mkdir -p "$FAKE/$vm" "/volume1/@kvm/$vm"
  printf '%s\n' "$3" >"$FAKE/$vm/state"
  printf '%s\n' "$2" >"$FAKE/$vm/title"
  qemu-img create -q -f qcow2 "/volume1/@kvm/$vm/disk.qcow2" 16M
  printf 'vda qcow2 /volume1/@kvm/%s/disk.qcow2\n' "$vm" >"$FAKE/$vm/disks"
}
HA=74be96f8-1c2d-4e3f-a0b1-e340c6e0637d
WIN=2f9c1a77-8d44-4b6a-9e21-5a7713cc0d10
PIHOLE=c81e0a42-3b5f-4d17-8a66-09be44f1d2a3
LAB=9d03f6b1-77a2-4c8e-b1d4-6ce2a18f7e55
new_vm "$HA" "Home Assistant" running
new_vm "$WIN" "Windows 11" running
new_vm "$PIHOLE" "Pi-hole" "shut off"
new_vm "$LAB" "Test server" running
touch "$FAKE/$HA/agent" "$FAKE/$WIN/uefi"

seed_backup() { # vm type job days-ago size
  local stamp dir
  stamp=$(date -d "$4 days ago 03:00" +%Y%m%d-%H%M%S)
  dir="/volume1/backup/vm/$1/$2-$3-$stamp"
  mkdir -p "$dir"
  printf 'format=1\ncreated=%s\nconsistency=filesystem\nsize=%s\n' "$(date -d "$4 days ago 03:00" +%s)" "$5" >"$dir/manifest.txt"
}
seed_snapshot() { # vm job hours-ago
  local epoch
  epoch=$(($(date +%s) - $3 * 3600))
  mkdir -p "$FAKE/$1/snapshots"
  printf 'ugvm-backup:job=%s\n%s\n' "$2" "$epoch" >"$FAKE/$1/snapshots/$1_$epoch"
}
for day in 1 2 3 4 5 6 7 9 10 11 14 15 16 17 18 20 21 22 25 26 27; do
  seed_backup "$HA" file nightly "$day" 18400000000
done
for day in 1 2 3 8 9 10 22 23 24; do
  seed_backup "$WIN" file nightly "$day" 64200000000
done
for day in 7 14 21 28; do
  seed_backup "$HA" ova weekly "$day" 12900000000
  seed_backup "$WIN" ova weekly "$day" 41000000000
done
for day in 12 13 14 15 16 17; do
  seed_backup "$PIHOLE" file nightly "$day" 2100000000
done
for hours in 6 30 54; do
  seed_snapshot "$HA" snap "$hours"
done

cat >/volume1/backup/vm-config.tmp <<'EOF'
version=1

[job]
id=nightly
name=Nightly to the backup drive
type=file
enabled=1
interval_hours=24
at=03:00
vms=*
keep_count=7
keep_days=30
target=/volume1/backup/vm
running_vm=live

[job]
id=weekly
name=Weekly OVA export
type=ova
enabled=1
interval_hours=168
at=02:30
vms=74be96f8-1c2d-4e3f-a0b1-e340c6e0637d,2f9c1a77-8d44-4b6a-9e21-5a7713cc0d10
keep_count=4
keep_days=0
target=/volume1/backup/vm
running_vm=shutdown

[job]
id=snap
name=Daytime snapshots
type=snapshot
enabled=1
interval_hours=24
at=12:00
vms=74be96f8-1c2d-4e3f-a0b1-e340c6e0637d
keep_count=3
keep_days=7
EOF
mkdir -p /volume1/backup/ugvm-backup
mv /volume1/backup/vm-config.tmp /volume1/backup/ugvm-backup/config.ini
printf '{"config_folder":"backup"}' >/app/data/settings.json

cd /src/app/backend
export UGAPP_SHARED_DIR=$SHARED UGAPP_DATA_DIR=/app/data UGAPP_INSTALL_DIR=/var/packages/io.github.cutzenfriend.vmbackup
export GOFLAGS=-buildvcs=false GOCACHE=/tmp/gocache
go build -o /tmp/ugvm_serv .
/tmp/ugvm_serv --port=21847 &
go run /src/tests/dev/devproxy.go &

while :; do
  ugvm-backup --config /volume1/backup/ugvm-backup >/dev/null 2>&1 || true
  /bin/sleep 20
done
