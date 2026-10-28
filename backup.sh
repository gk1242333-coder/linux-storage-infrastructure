#!/bin/bash
tar -czf /mnt/backup/data_$(date +%F_%H-%M).tar.gz -C /mnt data
echo "$(date) Backup done" >> /var/log/backup.log
