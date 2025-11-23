# homelab-infra
This playbook has the purpose of deploying running home infrastructure.
Ansible (playbooks, roles, inventory, docker compose templates)

# Conventions
* controller node: where the ansible script is running from
* target node: to deploy to

# Script in infra/boot folder
* Interactive script acquiring several parameters to 
    * Flashes Ubuntu USB stick for installation (amd64/arm64, latest LTS/non-LTS)
    * Flashes script for post-installation setting/installing/registering
        * hostname
        * ssh pub key
        * GitHub repo info
        * GitHub self-hosted runner to run Ansible on target node
        * self-destruction after first run (sensitive data)

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

# Commands CLI ansible
## On controller node
Location: $HOME/homelab/infra repo folder (where this current repo lives)
### Start Ansible deploy 
towards:
#### ha (local machine)
    ansible-playbook -i inventories/hosts site.yml -l ha -e env_file=../.env
#### ha_target
    ansible-playbook -i inventories/hosts site.yml -l ha_target -e "ansible_host=<target-ip>" -e env_file=../.env
### DOWN/UP target 
    ansible -i inventories/hosts ha_target \
    -m ansible.builtin.shell \
    -e "ansible_host=<target-ip>" \
    -a 'docker compose -p ha-stack-ansible -f "$HOME/homelab/target/ha-stack-ansible/docker-compose.yml" down'

    ansible -i inventories/hosts ha_target \
    -m ansible.builtin.shell \
    -e "ansible_host=<target-ip>" \
    -a 'docker compose -p ha-stack-ansible -f "$HOME/homelab/target/ha-stack-ansible/docker-compose.yml" up -d'
### Cleanup target

    ansible -i inventories/hosts ha_target -b -m shell -e "ansible_host=<target-ip>"  -a "rm -rf /home/ubuntu/homelab/target/*"

### Copy ssh key to target default location
This copies the default public key to ~/.ssh/id_ed25519.pub file to ~/.ssh/authorized_keys file immediately with the right permissions.

    ssh-copy-id ubuntu@<TARGET_IP>

### Backup
**making backups**

    ansible-playbook -i inventories/hosts site.yml -l ha_target -e "ansible_host=<target-ip>" --tags backup -vv

**checking backups**

    ansible -i inventories/hosts ha_target -e "ansible_host=<target-ip>" -m shell \
      -a 'ls -lt "$HOME/homelab/target/ha-stack-ansible/backup" | head -n 3'

**restore backup**\
(ha-config-20251105T165427.tar.gz as example)

    # W/o restore playbook
    ansible -i inventories/hosts ha_target \ 
    -e "ansible_host=<target-ip>" \
    -m shell -a \
    'tar -xzf /home/ubuntu/homelab/target/ha-stack-ansible/backup/ha-config-20251105T165427.tar.gz \
    -C /home/ubuntu/homelab/target/homeassistant-ansible \
    --strip-components=1'

    # With restore playbook + specific backup restore
    ansible-playbook -i inventories/hosts site.yml -l ha_target \
    -e "ansible_host=<target-ip>"
    -e env_file=../.env \
    --tags restore \
    -e ha_restore_backup=ha-config-20251105T165427.tar.gz
    
    # With restore playbook + last backup restore
    ansible-playbook -i inventories/hosts site.yml -l ha_target \
    -e "ansible_host=<target-ip>"
    -e env_file=../.env \
    --tags restore

    # Skip confirmation prompt (for automation later)
    ansible-playbook -i inventories/hosts site.yml -l ha_target \
    -e "ansible_host=<target-ip>"
    -e env_file=../.env \
    --tags restore \
    -e ha_restore_confirm=false

### HA Update
**first run for bootstrapping**

    ansible-playbook -i inventories/hosts site.yml -l ha_target -e "ansible_host=<target-ip>" -e env_file=../.env

**upgrade latest version**

    ansible-playbook -i inventories/hosts site.yml -l ha_target -e "ansible_host=<target-ip>" --tags ha_update

**upgrade specific version**

    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags ha_update -e "ansible_host=<target-ip>" -e ha_version_override=2025.10.5

**roll back: put lock back**

    ansible -i inventories/hosts ha_target -e "ansible_host=<target-ip>" -m copy \
      -a 'dest="{{ ha_stack_dir }}/.ha_version.lock" mode=0644 content="2025.10.3\n"'
    ansible-playbook -i inventories/hosts site.yml -l ha_target --tags ha_update

### Debugging
**list what ansible _thinks_ going to execute, eg:**

    ansible-playbook -i inventories/hosts site.yml -l ha_target -e "ansible_host=<target-ip>" -e env_file=../.env \
    --tags backups --list-tags --list-tasks

## On target node 
### Stopping target
    docker compose -p ha-stack-ansible -f "$HOME/homelab/target/ha-stack-ansible/docker-compose.yml" down

# TODO's:
* Attention for need for sudo pass **first time** to set nopassword!
* Move to GitHub actions as controller but with self-hosted runners on the target node
  * extra volume for local backups
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
