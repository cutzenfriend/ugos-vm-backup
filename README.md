# VM Backup for UGOS

Live backups of the VMs on a UGREEN NAS, from one script with a simple terminal interface. Running VMs are never shut down.

> **Status:** Early version. The backup method worked by hand on a real NAS, where the VM was frozen for 87 ms and the OVA imported into the Virtual Machine app. The complete script has only run against a stubbed `virsh` so far. Try it with an unimportant VM first and test a restore.

This is an independent project and is not affiliated with UGREEN.

## Install

Create a shared folder for your backups, for example `VMBackup` on Volume 1. Then connect to the NAS over SSH and run:

```bash
curl -fsSL https://raw.githubusercontent.com/cutzenfriend/ugos-vm-backup/main/ugvm-backup.sh -o /volume1/VMBackup/ugvm-backup.sh && sudo bash /volume1/VMBackup/ugvm-backup.sh
```

This downloads the script and opens the interface. If your folder has a different path, change it in both places.

In the interface:

1. **jobs** > **Create a job:** choose the VMs, the schedule and how long backups are kept.
2. **cron:** turn on the schedule. It adds one line to root's crontab, which runs every 10 minutes. The script only acts when a job is due.

To open the interface again:

```bash
sudo bash /volume1/VMBackup/ugvm-backup.sh
```

## Requirements

- UGOS with SSH access and an administrator account
- VM disks on a btrfs volume, without `nodatacow`
- `qemu-guest-agent` running inside each VM you back up while it runs
- `whiptail` and `curl`, which were already on the NAS this was tested on

`--check` shows whether your NAS and VMs meet these requirements. It changes nothing:

```bash
sudo bash /volume1/VMBackup/ugvm-backup.sh --check
```

## How a backup works

1. The guest agent freezes the file systems inside the VM.
2. btrfs clones the disk, which takes a moment because no data is copied yet.
3. The VM continues.
4. The script copies the clone to the backup folder, checks the copy and deletes the clone.

A powered-off VM is copied directly. If a running VM can't be frozen or its disk can't be cloned, the job fails with an error. The script doesn't fall back to copying a disk in use, because that can produce a damaged backup.

A frozen backup is as clean as a file system after a sync. Databases inside the VM may run their normal recovery when restored.

## Files

Everything stays in one folder:

```text
/volume1/VMBackup/
├── ugvm-backup.sh
├── config.ini
├── ugvm-backup.log
├── ugvm-state/
└── MyVM-1a2b3c4d/
    └── backup-<job>-<time>/
        ├── sda.qcow2
        ├── domain.xml
        ├── manifest.txt
        ├── nvram.fd            if the VM uses UEFI
        ├── tpm-state.tar.gz    if the VM has a TPM
        └── vm.ova              only if you created one
```

A backup folder only gets its final name once the copy is complete and checked.

## Jobs

| Type | What you get |
|---|---|
| Backup | A full copy of the disks and the VM definition |
| Snapshot | A snapshot inside the VM disk, named like those UGOS creates. It doesn't protect against drive failure. |

**Retention:** The count and age limits both apply, and 0 means no limit. The newest backup is never deleted, and nothing is deleted after a failed run. Only backups from the same job count, so snapshots you create manually in UGOS are left alone.

**Schedule:** A new job first runs at its next scheduled time. After a failure, the next attempt comes an hour later at the earliest.

## Restoring

**As a new VM:** Under **backups**, choose a backup and then **Create OVA for importing**. Import `vm.ova` in the Virtual Machine app. Disconnect the network before the first start if the original VM is still running, because the copy has the same hostname and services.

**Over an existing VM:** With the VM powered off, copy the disk back:

```bash
sudo cp <backup>/sda.qcow2 <disk-path-from-virsh-domblklist>
```

This overwrites the VM's current disk, including its UGOS snapshots.

## Commands

| Command | What it does |
|---|---|
| `--run` | Runs what is due, for cron |
| `--now JOB` | Runs one job immediately |
| `--ova BACKUP_DIR` | Creates an OVA from a backup, even if the VM no longer exists |
| `--check` | Shows what the script finds on this NAS |
| `--update [--yes]` | Updates the script from GitHub |
| `--version` | Shows the version |

## Updating

**update** in the interface compares your version with the one on GitHub and installs a newer one after you confirm. Cron never updates the script. The previous version stays next to it as `ugvm-backup.sh.previous`.

## Security

- The script runs as root from cron, so only people you trust as root should be able to write to its folder.
- `config.ini` is only read as data and is never executed. Invalid values are rejected.
- The disk format always comes from the VM definition, so a VM can't pull host files into a backup through a crafted disk.
- Updates come from this repository over HTTPS and aren't signed.

## Removing

1. Under **cron**, turn off the schedule.
2. Delete `ugvm-backup.sh`, `config.ini`, `ugvm-backup.log` and `ugvm-state` from the folder. Your backups are the folders next to them.

## Development

The tests run in a disposable Debian 12 container and also drive the real `whiptail` in a pseudo terminal:

```bash
bash tests/run-in-docker.sh
```

When you change the script, increase `VERSION` at the top of it. Otherwise `--update` won't offer the change to anyone.

## License

Released under the [MIT License](LICENSE).
