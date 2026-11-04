#!/usr/bin/env python3
"""Force the Solcast Solar integration's auto_update mode in .storage/core.config_entries.

DAYLIGHT mode (1) stops polling at sunset, so a decision automation running
after dark (e.g. at 22:00) always sees a stale pre-sunset forecast. ALL_DAY
mode (2) spreads the same daily API call budget across the full 24h instead,
guaranteeing a poll shortly before such a decision.

.storage/ is gitignored (runtime state, not IaC), so this setting does not
survive a fresh install or DR restore unless forced here.

Run while HA is STOPPED — HA reads core.config_entries at startup and can
flush its own in-memory copy back to disk on shutdown, clobbering an edit
made while it is still running.

Usage: python3 set_solcast_autoupdate.py <config_dir> <desired_auto_update_value>
"""
import json
import os
import sys


def main():
    config_dir, desired_value = sys.argv[1], int(sys.argv[2])
    entries_path = os.path.join(config_dir, ".storage", "core.config_entries")

    if not os.path.exists(entries_path):
        print("WARNING: core.config_entries not found — skipping (HA not yet bootstrapped)")
        sys.exit(0)

    with open(entries_path) as f:
        data = json.load(f)

    entry = next(
        (e for e in data["data"]["entries"] if e.get("domain") == "solcast_solar"),
        None,
    )
    if entry is None:
        print("WARNING: no solcast_solar config entry found — skipping")
        sys.exit(0)

    current = entry.get("options", {}).get("auto_update")
    if current == desired_value:
        print(f"Solcast auto_update already {desired_value} — no change needed")
        return

    entry.setdefault("options", {})["auto_update"] = desired_value

    with open(entries_path, "w") as f:
        json.dump(data, f, separators=(",", ":"))

    print(f"Solcast auto_update changed {current} -> {desired_value}")


if __name__ == "__main__":
    main()
