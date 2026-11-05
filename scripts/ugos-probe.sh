#!/usr/bin/env bash
#
# ugos-probe.sh - READ-ONLY diagnostics for the UGOS VM backup app.
#
# Answers the questions the UGREEN docs leave open: how libvirt is exposed,
# whether live backups are supported, and where UGOS keeps its VM data.
#
# It changes nothing: no VM is started, stopped or snapshotted, and no file
# outside the report is written. It prints no hostnames, serial numbers,
# passwords, shared folder names or file contents.
#
# Usage:  sudo bash ugos-probe.sh
# Report: ./ugos-probe-<timestamp>.txt  (mode 0600, please review before sharing)

set -u
export LC_ALL=C
umask 077

MAX_VMS=3
OUT="${UGOS_PROBE_OUT:-./ugos-probe-$(date +%Y%m%d-%H%M%S).txt}"
VIRSH=(virsh -c qemu:///system)

if command -v timeout >/dev/null 2>&1; then
  LIMIT=(timeout 30)
else
  LIMIT=()
fi

section() { printf '\n=== %s ===\n' "$1"; }

# Prints the command, then runs it. A failure is reported and never aborts,
# because a missing tool or path is itself a useful answer.
run() {
  printf '$ %s\n' "$*"
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '(not available: %s)\n' "$1"
    return 0
  fi
  "${LIMIT[@]+"${LIMIT[@]}"}" "$@" 2>&1 || printf '(exit code %s)\n' "$?"
}

probe() {
  section "Probe"
  printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'effective uid: %s\n' "$(id -u)"
  if [ "$(id -u)" -ne 0 ]; then
    printf 'WARNING: not running as root, many checks below will be incomplete.\n'
  fi

  section "System"
  run uname -srm
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null
  [ -r /etc/debian_version ] && printf 'debian_version: %s\n' "$(cat /etc/debian_version)"
  [ -r /sys/class/dmi/id/product_name ] && printf 'product: %s\n' "$(cat /sys/class/dmi/id/product_name)"
  printf 'version-like files in /etc:\n'
  ls /etc 2>/dev/null | grep -iE 'ugreen|ugos|nas.*ver|version' | head -20

  section "Installed virtualization packages"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -l 2>/dev/null | awk '/libvirt|qemu/ {print $2, $3}' | head -30
  else
    printf '(dpkg not available)\n'
  fi

  section "Tool versions"
  run virsh --version
  run qemu-img --version
  run tar --version

  section "Live backup capability"
  printf 'domain capabilities (looking for <backup supported="yes"/>):\n'
  "${LIMIT[@]+"${LIMIT[@]}"}" "${VIRSH[@]}" domcapabilities 2>&1 \
    | grep -iE '<backup|<domain>|<machine>|<arch>|error' | head -10
  run virsh help backup-begin
  run virsh help checkpoint-create

  section "libvirt sockets and groups"
  run ls -la /var/run/libvirt/
  for group in libvirt libvirt-qemu kvm; do
    # Name and gid only, the member list could contain user names.
    getent group "$group" 2>/dev/null | cut -d: -f1,3
  done

  section "Storage layout"
  run df -h /volume1 /volume2 /volume3
  printf 'system folders (@*) on volumes, shared folders are not listed:\n'
  ls -d /volume*/@* 2>/dev/null | head -40
  for kvm_dir in /volume*/@kvm; do
    [ -d "$kvm_dir" ] && run ls -la "$kvm_dir"
  done

  section "UGOS VM app files (names only)"
  for app_dir in /volume*/@appstore/com.ugreen.kvm /volume*/@appdata/com.ugreen.kvm; do
    [ -e "$app_dir" ] || continue
    printf '%s:\n' "$app_dir"
    find "$app_dir" -maxdepth 2 \( -name '*.db' -o -name '*.sqlite*' -o -name '*.json' \
      -o -name '*.yaml' -o -name '*.yml' -o -name '*.conf' \) 2>/dev/null | head -30
  done

  section "Virtual machines (first ${MAX_VMS} in detail, UUIDs only)"
  vms=$("${LIMIT[@]+"${LIMIT[@]}"}" "${VIRSH[@]}" list --all --name 2>/dev/null | grep -v '^$')
  printf 'count: %s\n' "$(printf '%s\n' "$vms" | grep -c .)"
  printf '%s\n' "$vms" | head -n "$MAX_VMS" | while IFS= read -r vm; do
    [ -n "$vm" ] || continue
    probe_vm "$vm"
  done

  section "App lifecycle scripts in installed apps (names only)"
  printf 'apps: %s\n' "$(ls /var/packages 2>/dev/null | wc -l | tr -d ' ')"
  find /volume*/@appstore -maxdepth 3 \( -name 'install.sh' -o -name 'update.sh' \
    -o -name 'uninstall.sh' -o -name 'preinst' -o -name 'postinst' -o -name 'prerm' \
    -o -name 'postrm' \) 2>/dev/null | head -20

  section "How app processes run (user and executable only)"
  # Only the first two fields: arguments could contain tokens.
  ps -eo user:24,args 2>/dev/null | grep -E '/@appstore/|/var/packages/' | grep -v grep \
    | awk '{print $1, $2}' | sort -u | head -30

  section "Services and persistence"
  command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --no-pager --plain 2>/dev/null \
    | awk '{print $1, $3, $4}' | grep -iE 'libvirt|kvm|qemu|ugreen|appstore|app_' | head -30
  run findmnt -no FSTYPE,OPTIONS /
  run findmnt -no FSTYPE,OPTIONS /etc
  printf 'custom units in /etc/systemd/system: %s\n' \
    "$(ls /etc/systemd/system 2>/dev/null | grep -c '\.service$')"

  section "Local listeners relevant to the VM app"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E 'libvirt|kvm|qemu|:9443 |:9999 ' | awk '{print $4, $6}' | head -20
  else
    printf '(ss not available)\n'
  fi

  printf '\n=== Done. Nothing was changed. ===\n'
}

probe_vm() {
  local vm="$1"
  section "VM ${vm}"
  run "${VIRSH[@]}" domstate "$vm"

  # dumpxml omits secrets without --security-info. Only counts are reported.
  local xml
  xml=$("${VIRSH[@]}" dumpxml "$vm" 2>/dev/null)
  printf 'guest agent channel: %s\n' "$(printf '%s' "$xml" | grep -c 'org.qemu.guest_agent')"
  printf 'uefi loader/nvram lines: %s\n' "$(printf '%s' "$xml" | grep -cE '<loader|<nvram')"
  printf 'tpm devices: %s\n' "$(printf '%s' "$xml" | grep -c '<tpm')"

  # Disks only: CD-ROM entries could reveal ISO paths inside shared folders.
  local disks
  disks=$("${VIRSH[@]}" domblklist "$vm" --details 2>/dev/null | awk '$2 == "disk" {print $3, $4, $1}')
  printf 'disks (target path type):\n%s\n' "$disks"

  run "${VIRSH[@]}" snapshot-list "$vm"
  local first_snapshot
  first_snapshot=$("${VIRSH[@]}" snapshot-list "$vm" --name 2>/dev/null | head -n 1)
  [ -n "$first_snapshot" ] && run "${VIRSH[@]}" snapshot-info "$vm" "$first_snapshot"

  printf '%s\n' "$disks" | while read -r _target path _type; do
    [ -n "${path:-}" ] || continue
    printf 'qemu-img info: %s\n' "$path"
    qemu-img info -U "$path" 2>&1 \
      | grep -E '^(file format|virtual size|disk size|cluster_size|backing file)|Snapshot list|error'
    run ls -la "$(dirname "$path")"
  done
}

probe 2>&1 | tee "$OUT"
printf '\nReport saved to %s\n' "$OUT"
