#!/usr/bin/env python3
"""Configure HA backup encryption key via REST API.

Runs inside the HA container (localhost:PORT accessible).
Uses password grant to get a short-lived token — no long-lived token needed.

Usage: python3 configure_backup_key.py <port> <username> <password> <backup_key>
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


def main():
    port, username, password, backup_key = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    base = f"http://localhost:{port}"

    # 1. Get short-lived token via password grant
    data = urllib.parse.urlencode({
        "client_id": f"{base}/",
        "grant_type": "password",
        "username": username,
        "password": password,
    }).encode()

    try:
        with urllib.request.urlopen(
            urllib.request.Request(
                f"{base}/auth/token",
                data=data,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
        ) as r:
            token = json.loads(r.read())["access_token"]
    except urllib.error.HTTPError as e:
        print(f"ERROR: Failed to get token: HTTP {e.code} - {e.read().decode()}", file=sys.stderr)
        sys.exit(1)

    # 2. Update backup encryption key
    body = json.dumps({"create_backup": {"password": backup_key}}).encode()

    try:
        with urllib.request.urlopen(
            urllib.request.Request(
                f"{base}/api/backup/config/update",
                data=body,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            )
        ) as r:
            result = json.loads(r.read())
            configured_password = (
                result.get("config", {}).get("create_backup", {}).get("password")
            )
            if configured_password == backup_key:
                print("Backup encryption key configured successfully")
            else:
                print("Backup key set (response format differs from expected)")
    except urllib.error.HTTPError as e:
        print(f"ERROR: Failed to update backup config: HTTP {e.code} - {e.read().decode()}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
