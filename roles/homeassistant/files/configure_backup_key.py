#!/usr/bin/env python3
"""Set HA backup encryption key directly in .storage/backup.

Writes the password from HA_BACKUP_ENCRYPT_KEY into .storage/backup so HA
always uses the known key from secrets for future backups.

Run while HA is STOPPED — HA reads .storage/backup at startup.

Usage: python3 configure_backup_key.py <config_dir> <backup_key>
"""
import json
import os
import sys


def main():
    config_dir, backup_key = sys.argv[1], sys.argv[2]
    backup_path = os.path.join(config_dir, ".storage", "backup")

    if not os.path.exists(backup_path):
        # Create minimal backup config if file doesn't exist yet
        data = {
            "version": 1,
            "minor_version": 7,
            "key": "backup",
            "data": {
                "backups": [],
                "config": {
                    "agents": {},
                    "automatic_backups_configured": False,
                    "create_backup": {
                        "agent_ids": ["backup.local"],
                        "include_addons": None,
                        "include_all_addons": False,
                        "include_database": True,
                        "include_folders": None,
                        "name": None,
                        "password": backup_key,
                    },
                    "last_attempted_automatic_backup": None,
                    "last_completed_automatic_backup": None,
                    "retention": {"copies": 10, "days": None},
                    "schedule": {"days": [], "recurrence": "never", "time": None},
                },
            },
        }
        print("Created new .storage/backup with backup key")
    else:
        with open(backup_path) as f:
            data = json.load(f)

        current = (
            data.get("data", {})
            .get("config", {})
            .get("create_backup", {})
            .get("password")
        )

        data.setdefault("data", {}).setdefault("config", {}).setdefault(
            "create_backup", {}
        )["password"] = backup_key

        if current == backup_key:
            print("Backup key already correct — no change needed")
        else:
            print(f"Backup key updated (was: {'(none)' if current is None else '(set)'})")

    with open(backup_path, "w") as f:
        json.dump(data, f)


if __name__ == "__main__":
    main()
