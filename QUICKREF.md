# 📖 Quick Reference Guide

One-page cheat sheet for common homelab operations.

## 🚀 Quick Deploys

```bash
# Standard deploy:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env

# Fresh install (clean .storage/):
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -e fresh_install=true

# Specific version:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -e ha_version_override=2025.12.4

# Local deployment (on same machine):
ansible-playbook -i inventories/ha_target_local.ini site.yml -l ha -e env_file=../.env

# GitHub Actions (with version override):
GitHub → Actions → Deploy Home Assistant → Run workflow
→ ha_version_override: 2025.12.4
```

## 🐳 Container Management

```bash
# Stop stack:
docker compose -p ha-stack-ansible -f ~/homelab/target/ha-stack-ansible/docker-compose.yml down

# Start stack:
docker compose -p ha-stack-ansible -f ~/homelab/target/ha-stack-ansible/docker-compose.yml up -d

# Restart HA only:
docker restart homeassistant_ansible

# View logs:
docker logs homeassistant_ansible --tail 100 --follow

# List containers:
docker ps --filter "name=homeassistant\|cloudflared\|code_server\|esphome"
```

## 🔄 Version Management

```bash
# Update to latest:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target --tags ha_update

# Update to specific version:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target --tags ha_update -e ha_version_override=2025.12.4

# Check current version:
cat ~/homelab/target/ha-stack-ansible/.ha_version.lock

# Roll back:
echo "2025.10.3" > ~/homelab/target/ha-stack-ansible/.ha_version.lock
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target --tags ha_update
```

## 🔍 Debugging

```bash
# Test connectivity:
ansible -i inventories/ha_target_remote.ini ha_target -m ping

# Verbose deploy:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -vvv

# List tasks:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target --list-tasks

# Dry run:
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env --check
```

## 💾 Disaster Recovery

```bash
# Test with backup:
# 1. Ensure backup exists: ls /mnt/backup/homeassistant/*.tar
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -e fresh_install=true

# Test with seedbox:
# 1. Remove backups: rm /mnt/backup/homeassistant/*.tar
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -e fresh_install=true

# Test bootstrap:
# 1. Remove backups
# 2. Stop seedbox: ssh root@192.168.3.8 "docker stop homeassistant"
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env -e fresh_install=true
```

## 🔑 SSH Operations

```bash
# Copy SSH key to target:
ssh-copy-id ubuntu@<TARGET_IP>

# Test SSH:
ssh ubuntu@<TARGET_IP>

# SSH with specific key:
ssh -i ~/.ssh/id_ed25519 ubuntu@<TARGET_IP>
```

## 📊 Service URLs

```bash
# Home Assistant:
http://<TARGET_IP>:8123

# Code Server:
https://<TARGET_IP>:8443

# ESPHome:
http://<TARGET_IP>:6052

# SSH Terminal:
ssh -p 2222 <username>@<TARGET_IP>

# Samba:
\\<TARGET_IP>\homeassistant
```

## 🛠️ On-Target Operations

```bash
# SSH to target:
ssh ubuntu@<TARGET_IP>

# Check disk usage:
du -sh ~/homelab/target/homeassistant-ansible/config/.storage/

# View .storage contents:
ls -la ~/homelab/target/homeassistant-ansible/config/.storage/

# Check container status:
docker ps -a

# Enter container:
docker exec -it homeassistant_ansible bash

# View HA logs inside container:
docker exec homeassistant_ansible tail -f /config/home-assistant.log
```

## 🤖 GitHub Self-hosted Runner

```bash
# Check runner status (on target):
systemctl status actions.runner.*

# Restart runner:
cd ~/actions-runner
sudo ./svc.sh restart

# View runner logs:
cd ~/actions-runner
tail -f _diag/Runner_*.log

# Manual workflow trigger:
# 1. Go to GitHub → Actions
# 2. Select "Deploy Home Assistant"
# 3. Click "Run workflow"
```

## 🆘 Emergency Recovery

```bash
# Complete cleanup and redeploy:
ansible -i inventories/ha_target_remote.ini ha_target -b -m shell -a "rm -rf /home/ubuntu/homelab/target/*"
ansible-playbook -i inventories/ha_target_remote.ini site.yml -l ha_target -e env_file=../.env

# Nuclear option (requires re-run setup-machine.sh):
sudo rm -rf ~/homelab ~/actions-runner
```

## 📁 Important Files

```bash
# Version lock:
~/homelab/target/ha-stack-ansible/.ha_version.lock

# Docker compose:
~/homelab/target/ha-stack-ansible/docker-compose.yml

# HA config:
~/homelab/target/homeassistant-ansible/config/configuration.yaml

# HA state:
~/homelab/target/homeassistant-ansible/config/.storage/

# Backups:
/mnt/backup/homeassistant/*.tar

# Logs:
docker logs homeassistant_ansible
~/homelab/target/homeassistant-ansible/config/home-assistant.log
```

## 🔥 Common Issues → Quick Fixes

| Issue | Quick Fix |
|-------|-----------|
| Can't SSH to target | `ssh-copy-id ubuntu@<IP>` |
| Container won't start | `docker logs homeassistant_ansible` |
| Ansible timeout | `ansible -i inventories/ha_target_remote.ini ha_target -m ping` |
| Wrong HA version | Edit `.ha_version.lock` + run `--tags ha_update` |
| No seedbox found | Check seedbox is running: `nmap -p 8123 192.168.3.0/24` |
| Bootstrap didn't run | Restore succeeded (check Ansible output) |

## 💡 Pro Tips

```bash
# Always from ~/homelab/infra directory:
cd ~/homelab/infra

# Keep .env in parent directory:
ls ../.env

# Test Ansible connectivity before long deploys:
ansible -i inventories/ha_target_remote.ini ha_target -m ping

# Use --check for dry runs:
ansible-playbook ... --check

# Save deploy output:
ansible-playbook ... 2>&1 | tee deploy.log

# Quick container restart:
docker restart homeassistant_ansible

# View all container resources:
docker stats
```
