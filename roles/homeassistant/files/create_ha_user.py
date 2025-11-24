#!/usr/bin/env python3
"""
Create Home Assistant user with proper credentials for HA 2025.11+
This script directly manipulates the auth database to create a complete user entry
and marks onboarding as complete.
"""

import json
import sys
import secrets
import base64
from pathlib import Path

# Paths
AUTH_FILE = Path("/config/.storage/auth")
AUTH_PROVIDER_FILE = Path("/config/.storage/auth_provider.homeassistant")
ONBOARDING_FILE = Path("/config/.storage/onboarding")

def generate_user_id():
    """Generate a UUID-like user ID."""
    return secrets.token_hex(16)

def hash_password(password):
    """Create bcrypt-style password hash and base64 encode it."""
    import bcrypt
    # Create bcrypt hash
    bcrypt_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    # Base64 encode for HA storage
    return base64.b64encode(bcrypt_hash.encode('utf-8')).decode('utf-8')

def create_user(username, password):
    """Create a complete user with credentials and mark onboarding complete."""
    
    # Read existing auth file
    if not AUTH_FILE.exists():
        print(f"ERROR: {AUTH_FILE} does not exist!")
        sys.exit(1)
    
    with open(AUTH_FILE) as f:
        auth_data = json.load(f)
    
    # Check if user already exists
    users = auth_data.get("data", {}).get("users", [])
    for user in users:
        if not user.get("system_generated", False):
            print(f"User already exists: {user.get('name', 'Unknown')}")
            return False
    
    # Generate new user
    user_id = generate_user_id()
    credential_id = generate_user_id() + "cred"
    
    # Create user entry
    new_user = {
        "id": user_id,
        "group_ids": ["system-admin"],
        "is_owner": True,
        "is_active": True,
        "name": username,
        "system_generated": False,
        "local_only": False
    }
    
    # Create credential entry
    password_hash = hash_password(password)
    new_credential = {
        "id": credential_id,
        "user_id": user_id,
        "auth_provider_type": "homeassistant",
        "auth_provider_id": None,
        "data": {
            "username": username
        }
    }
    
    # Remove system-generated users
    auth_data["data"]["users"] = [u for u in users if not u.get("system_generated", False)]
    
    # Add new user
    auth_data["data"]["users"].append(new_user)
    
    # Add credential
    if "credentials" not in auth_data["data"]:
        auth_data["data"]["credentials"] = []
    auth_data["data"]["credentials"].append(new_credential)
    
    # Clean up orphaned refresh tokens
    valid_user_ids = [u["id"] for u in auth_data["data"]["users"]]
    original_tokens = len(auth_data["data"].get("refresh_tokens", []))
    auth_data["data"]["refresh_tokens"] = [
        t for t in auth_data["data"].get("refresh_tokens", [])
        if t.get("user_id") in valid_user_ids
    ]
    removed_tokens = original_tokens - len(auth_data["data"]["refresh_tokens"])
    if removed_tokens > 0:
        print(f"Cleaned up {removed_tokens} orphaned refresh tokens")
    
    # Write updated auth file
    with open(AUTH_FILE, 'w') as f:
        json.dump(auth_data, f, indent=2)
    
    # Create auth_provider file
    auth_provider_data = {
        "version": 1,
        "minor_version": 1,
        "key": "auth_provider.homeassistant",
        "data": {
            "users": [
                {
                    "username": username,
                    "password": password_hash
                }
            ]
        }
    }
    
    with open(AUTH_PROVIDER_FILE, 'w') as f:
        json.dump(auth_provider_data, f, indent=2)
    
    # Mark onboarding as complete
    onboarding_data = {
        "version": 4,
        "minor_version": 1,
        "key": "onboarding",
        "data": {
            "done": ["user", "core_config", "integration", "analytics"]
        }
    }
    
    with open(ONBOARDING_FILE, 'w') as f:
        json.dump(onboarding_data, f, indent=2)
    
    print(f"✅ User '{username}' created successfully!")
    print(f"   User ID: {user_id}")
    print(f"   Group: system-admin (Administrator)")
    print(f"   Owner: Yes")
    print(f"✅ Onboarding marked as complete")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: create_ha_user.py <username> <password>")
        sys.exit(1)
    
    username = sys.argv[1]
    password = sys.argv[2]
    
    create_user(username, password)
