# homelab-infra
This playbook has the purpose of deploying running home infrastructure.
Ansible (playbooks, roles, inventory, docker compose templates)

# Conventions
* controller: node where the ansible script is running from
* target: node to deploy to

# Hard dependencies
* The following private repo is being used for deployment:  
https://github.com/johantre/homelab-config
* .env file on the controller containing all secrets (in GH secrets later on)

# Hidden dependencies
Implicit things to remember:
* On controller node, the SSH public and private keys in the default location 
  * ~/.ssh/id_ed25519
  * ~/.ssh/id_ed25519.pub
* On target node, the SSH Public key in default location 
  * ~/.ssh/authorized_keys \
    authorized_keys and id_ed25519.pub should be identical.

# Commands in CLI
## From the controller
Location: $HOME/homelab/infra repo folder (where this current repo lives)
### Start Ansible deploy 
towards:
#### ha (local machine)
    ansible-playbook -i inventories/hosts site.yml -l ha -e env_file=../.env
#### ha_target
    ansible-playbook -i inventories/hosts site.yml -l ha_target -e env_file=../.env
### Stopping target 
    ansible -i inventories/hosts ha_target \
    -m ansible.builtin.command \
    -a "docker compose -p ha-stack-ansible -f $HOME/homelab/target/ha-stack-ansible/docker-compose.yml down"
### Copy ssh key to target default location
This copies the default public key to ~/.ssh/id_ed25519.pub file to ~/.ssh/authorized_keys file immediately with the right permissions.

    ssh-copy-id ubuntu@<TARGET_IP>

### Backup
* making backups


    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags backup -vv
* checking backups


    ansible -i inventories/hosts ha_target -m shell \
      -a 'ls -lt "$HOME/homelab/target/ha-stack-ansible/backup" | head -n 3'

### HA Update
* first run for bootstrapping


    ansible-playbook -i inventories/hosts site.yml -l ha_target -e env_file=../.env
* upgrade latest version


    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags ha_update
* upgrade specific version


    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags ha_update -e ha_version_override=2025.10.5
* roll back: put lock back 


    ansible -i inventories/hosts ha_target -m copy \
      -a 'dest="{{ ha_stack_dir }}/.ha_version.lock" mode=0644 content="2025.10.3\n"'
    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags ha_update


## From the target 
### Stopping target
    docker compose -p ha-stack-ansible -f "$HOME/homelab/target/ha-stack-ansible/docker-compose.yml" down

# TODO's:
* Attention for need for sudo pass **first time** to set nopassword!
* Move to GitHub actions as controller w Tailscale/WireGuard (complete hands-off)
* Fix this with hands-off installation media with 2 volumes 
  * Latest Ubuntu Server installer
  * on separate volume CIDATA met user-data + meta-data \
  that assures ssh-server, docker, git, mac-randomization off... NOPASSWD is configured during silent ubuntu install/flash.
  * OR with network seed, wo CIDATA volume
* Deployment from fresh ubuntu flashed disk
* Test deployment is working
* Autoinstall + cloud-init (NoCloud) met Ansible pull-model
* Continuous 
    * backup strategy (to serve as disaster recovery)
    * update strategy (deployments, as well as infra)
    * test strategy: OS, docker, git, Ansible, ...
      * deploys _keep_ working
      * updates _keep_ working
      * backups _keep_ working
