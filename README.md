# homelab-infra
Ansible (playbooks, roles, inventory, docker compose templates)

controller: node where the ansible script is running from
target: node to deploy to

We use the standard location for the SSH key on the controller (~/.ssh/id_ed25519).”


TODO's:
Attention for need for sudo pass first time to set nopassword. 
Fix this with hands-off installation, on separate volume that assures ssh-server, ... nopass is configure during silent ubuntu install/flash

# Commands to run from controller environment

## Start Ansible to deploy
From controller infra repo folder: 
### ha_target
ansible-playbook -i inventories/hosts site.yml -l ha_target -e env_file=../.env
### ha (local machine)
ansible-playbook -i inventories/hosts site.yml -l ha -e env_file=../.env

## Stopping target 
ansible -i inventories/hosts ha_target \
-m ansible.builtin.command \
-a "docker compose -p ha-stack-ansible -f /home/ubuntu/homelab/target/ha-stack-ansible/docker-compose.yml down"

##