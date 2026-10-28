#!/bin/bash
LOG=/var/log/storage_monitor.log
echo "===$(date)===" >> $LOG
df -h /mnt/data /mnt/backup >> $LOG
vgs >> $LOG
lvs >> $LOG
for mp in /mnt/data /mnt/backup; do
df --output=pcent $mp > /tmp/usage.txt
USAGE=$(sed -n 2p /tmp/usage.txt)
USAGE=${USAGE//[ %]/}
if [ $USAGE -gt 80 ]; then echo "WARNING: $mp is ${USAGE}% full" >> $LOG; fi
done
