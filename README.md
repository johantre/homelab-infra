# homelab-infra
This playbook has the purpose of deploying running home infrastructure.
Ansible (playbooks, roles, inventory, docker compose templates)

# Conventions
* controller: node where the ansible script is running from
* target: node to deploy to

# Hard dependencies
The following private repo is being used for deployment:  
https://github.com/johantre/homelab-config 

# Hidden dependencies
Implicit things to remember:
We use the standard location for the SSH key on the controller (~/.ssh/id_ed25519).

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

## From the target 
### Stopping target
    docker compose -p ha-stack-ansible -f "$HOME/homelab/target/ha-stack-ansible/docker-compose.yml" down

# TODO's:
* Attention for need for sudo pass **first time** to set nopassword!
* Move to GitHub actions as controller w Tailscale/WireGuard (complete hands-off)
* Fix this with hands-off installation media with 2 volumes 
  * Latest Ubuntu Server installer
  * on separate volume CIDATA met user-data + meta-data \
  that assures ssh-server, docker, git, ... NOPASSWD is configured during silent ubuntu install/flash.
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
 