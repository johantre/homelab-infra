#!/usr/bin/env python3
"""Inject a known long-lived token from secrets into HA's auth storage.

Writes the token from HA_LONG_LIVED_TOKEN_GH_ACTIONS_GIT_SYNC directly
into .storage/auth so HA accepts it as a valid long-lived access token.

Run while HA is STOPPED — HA reads .storage/auth at startup.

Usage: python3 inject_ha_token.py <config_dir> <username> <token_value>
"""
import json
import os
import secrets
import sys
import uuid
from datetime import datetime, timezone


def main():
    config_dir, username, token_value = sys.argv[1], sys.argv[2], sys.argv[3]
    auth_path = os.path.join(config_dir, ".storage", "auth")

    with open(auth_path) as f:
        auth_data = json.load(f)

    # Find user_id by matching username in credentials
    user_id = None
    for cred in auth_data["data"].get("credentials", []):
        if cred.get("data", {}).get("username") == username:
            user_id = cred["user_id"]
            break

    if not user_id:
        print(f"WARNING: No credentials found for user '{username}' — skipping token injection")
        print("This is expected in maintenance mode when HA was not deployed via bootstrap.")
        sys.exit(0)

    # Remove any existing GitHub Actions token (idempotent re-runs)
    before = len(auth_data["data"]["refresh_tokens"])
    auth_data["data"]["refresh_tokens"] = [
        t for t in auth_data["data"]["refresh_tokens"]
        if t.get("client_name") != "GitHub Actions"
    ]
    removed = before - len(auth_data["data"]["refresh_tokens"])
    if removed:
        print(f"Removed {removed} existing 'GitHub Actions' token(s)")

    # Inject new token entry
    auth_data["data"]["refresh_tokens"].append({
        "id": secrets.token_hex(32),
        "user_id": user_id,
        "client_id": None,
        "client_name": "GitHub Actions",
        "client_icon": None,
        "token_type": "long_lived_access_token",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "access_token_expiration": 1800.0,
        "token": token_value,
        "jwt_key": secrets.token_hex(64),
        "last_used_at": None,
        "last_used_ip": None,
        "expire_at": None,
        "credential_id": None,
        "version": None,
    })

    with open(auth_path, "w") as f:
        json.dump(auth_data, f)

    print(f"Long-lived token injected for user '{username}' (user_id: {user_id})")


if __name__ == "__main__":
    main()
