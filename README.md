# Integrated Linux Storage Infrastructure

A complete storage system on Ubuntu, built with Bash scripting and Linux commands only, with a menu-driven front end.

## What it does
- Divides a disk into partitions (`parted`)
- Manages flexible storage with LVM (PV, VG, LV) and ext4 filesystems
- Extends a volume online and takes snapshots
- Backs up data with `tar` and restores it
- Automates backup and monitoring with `cron`
- Writes a WARNING when disk usage is above 80%
- Provides a 10-option menu in the terminal with input checking and error handling

## Environment
Ubuntu 25.04 in Oracle VirtualBox, 10 GB extra virtual disk (`/dev/sdb`).

## Files
| File | Purpose |
|---|---|
| `storage_manager.sh` | Menu-driven interface (front end) |
| `backup.sh` | Compresses `/mnt/data` into `/mnt/backup` |
| `monitor.sh` | Logs disk usage and writes a WARNING above 80% |

## How to run
```bash
sudo cp storage_manager.sh backup.sh monitor.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/storage_manager.sh /usr/local/bin/backup.sh /usr/local/bin/monitor.sh
sudo storage_manager.sh
```
The menu needs the LVM volume group `vg_storage` and the folders `/mnt/data` and `/mnt/backup` to exist, as set up in the project report.

## Cron jobs
```
0 2 * * * /usr/local/bin/backup.sh
*/10 * * * * /usr/local/bin/monitor.sh
```

## Menu options
1 Overview, 2 Partitions, 3 Create LV, 4 Extend LV, 5 Snapshots, 6 Backup, 7 Restore, 8 Usage check, 9 Cron, 10 Logs, 0 Exit.

## Team
Linux System Administration (E1ITA307), Alliance University.
Pruthviraj M, Mariyani Vishal, Ganesh Koti, Rohan Pujeri.
