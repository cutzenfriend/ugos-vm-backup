# VM Backup for UGOS

Backs up the VMs of the UGOS Virtual Machine app. It creates snapshots, file backups and OVA exports, each with its own schedule, target folder and retention limits by count and age.

> **Status:** Tested against a stubbed `virsh` and the real `qemu-img`, but it has not run on a real UGREEN NAS yet. Start with a throwaway VM and work through the [checks below](#checks-on-the-nas).

This is an independent project and is not affiliated with UGREEN.

## How it works

| Part | Runs as | Job |
|---|---|---|
| **App** (`.upk`) | Non-root, in the UGOS sandbox | Provides the interface, writes `config.ini`, reads the status |
| **Script** (`ugvm-backup`) | root, from cron every 10 minutes | Checks what is due and runs the backups |

The two only communicate through files in the config folder you choose. No stored password or permanently running root service is needed.

| Type | What you get | Can the VM keep running? |
|---|---|---|
| Snapshot | An internal snapshot in the VM disk, like those UGOS creates | Yes, with a short pause. It doesn't protect against drive failure. |
| File backup | Copies of the disks as qcow2, plus the VM definition, UEFI variables and TPM state | Your choice: live, shut down or skip |
| OVA export | A single `vm.ova` plus the VM definition | Same choice as file backups |

Backups are stored in `<target folder>/<VM ID>/<type>-<job>-<time>/`. A folder only gets this name once the copy is complete and verified.

**Retention:** The count and age limits both apply, and 0 means no limit. The newest backup is never deleted, and nothing is deleted after a failed run. Only backups from the same job count, so snapshots you create manually in UGOS are left alone.

**Schedule:** A new job first runs at its next scheduled time, so saving a job never shuts down a VM. After a failure, the next attempt comes an hour later at the earliest.

## Installation

You need UGOS Pro firmware 1.13 or later, SSH access, an administrator account, and Docker on the computer you build with.

1. **Build the packages.** They end up in `dist/`:

   ```bash
   bash build/build.sh
   ```

2. **Allow custom packages.** On firmware 1.16 and later, go to App Center > Settings > App Development Settings. Earlier versions need a `ugdev.sig` from UGREEN.
3. **Install the package.** Use manual installation in App Center and pick the file for your CPU: `amd64` for Intel and AMD (such as DXP models), `arm64` for ARM.
4. **Authorize folders.** In the app's App Center settings, allow the folders for the config and your backups.
5. **Open the app and follow the Setup tab.** It shows the exact commands for your system to install the script and create the cron job.

Only administrators should be able to write to the config folder. Anyone who can write there can trigger or redirect backups, even though the script validates every value.

## Checks on the NAS

These questions can't be settled without a real device. This read-only diagnostic script partly answers check 4:

```bash
sudo bash scripts/ugos-probe.sh
```

Its report describes your system, so read it before you share it.

| # | Question | If it fails |
|---|---|---|
| 1 | Does the app start and open in the UGOS window? | The backend only listens on `127.0.0.1`. If UGOS can't reach it there, add `--listen` in `project.yaml`. |
| 2 | Does Setup show authorized folders with a `/volumeN/…` path? | The app reads the path from the folder's symlink. If the sandbox shows something else, the mapping needs changing. |
| 3 | Does the install command find `/var/packages/<app>/libexec/ugvm-backup.sh`? | Correct the path using the error message. |
| 4 | Does a live backup of a running VM work? | QEMU must be able to write to the target folder. Otherwise choose the shutdown option in the job. |
| 5 | Do this app's snapshots appear correctly in the UGOS interface? | If not, don't use snapshot jobs. File backups aren't affected. |
| 6 | Can the Virtual Machine app import the generated `vm.ova`? | Use file backups until the OVF is adjusted. |
| 7 | Does the cron job survive a UGOS update? | The Overview warns after 30 minutes without a report from the script and shows the line again. |
| 8 | Can a file backup actually be restored? | This applies to any backup tool: only a successful restore proves a backup works. |

## Restoring

A file backup is a regular qcow2 disk. With the VM powered off, copy it back over SSH:

```bash
sudo cp <backup>/vda.qcow2 <disk-path-from-virsh-domblklist>
```

OVA files can be imported in the Virtual Machine app (see check 6), and snapshots restored in the UGOS interface.

## Removing

1. Remove the line from root's crontab with `sudo crontab -e`.
2. Delete the script and its state:

   ```bash
   sudo rm -rf /usr/local/sbin/ugvm-backup /var/lib/ugvm-backup
   ```

3. Uninstall the app in App Center. Your backups are kept.

## Security

- **The script is the security boundary.** It treats `config.ini` as untrusted: it reads it line by line, checks it against fixed patterns, and never executes it.
- **Target folders** must be under `/volumeN/`, with no `..` and no `@` system folders such as `@kvm`, even after symlinks are resolved.
- **The disk format** always comes from the VM definition, so a VM can't pull host files into a backup through a crafted disk.
- **Self-protection:** The script refuses to start if non-root users can change it or its folder.
- **No commands from the app:** It can only save settings and request a run. It needs no `permissions` entry and no `SYSTEM.EXEC_SYSTEM_COMMAND`.
- **Access** is limited to administrators, checked through the headers set by the UGOS gateway.

Remaining risk: the script runs as root. Between its check and its write, someone with write access to the target folder could swap folders there. The damage is limited because the script only writes fixed file names, but only administrators should be able to write to the target and config folders.

## Development

Everything runs in Docker, and nothing is installed on the host.

```bash
bash tests/run-in-docker.sh
```

```bash
bash build/build.sh 2
```

The build number must increase for the same version, or UGOS won't accept the update. When you change the script, increase `VERSION` in the script and `scriptVersion` in `app/backend/server.go`. A test checks that they match.

To work on the interface, this starts a test environment with stubbed VMs at http://localhost:8099:

```bash
docker run --rm --name ugvm-dev -p 8099:8099 -v "$PWD:/src:ro" golang:1.25-bookworm bash /src/tests/dev/run-in-container.sh
```

An App Center store listing is unlikely, because the app depends on a root cron job.
