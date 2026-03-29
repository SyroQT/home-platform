# Ansible Setup

These steps configure the server after the infrastructure has been created with Terraform.

## Generate Ansible Variables

Generate Ansible variables from Terraform:

```bash
sh bootstrap/scripts/render-ansible-vars.sh
```

## Prepare Inventory

Change into `bootstrap/ansible` and ensure `inventories/prod/hosts.ini` has `ansible_user=root`.

## Verify Inventory Variables

Check whether Ansible sees the generated variables:

```bash
ansible-inventory -i inventories/prod/hosts.ini --host vps-prod
```

## Verify SSH Access

Check whether Ansible can access the VPS:

```bash
ansible -i inventories/prod/hosts.ini vps -m ping -e ansible_user=root
```

To remove an old key from local `known_hosts`, run:

```bash
ssh-keygen -R <VPS_IP_ADDRESS>
ssh-keygen -R vps-prod
```

Then `ssh` into the VPS once to add the new host key.

## Run the Hardening Playbook

Run the playbook as `root` for the initial setup:

```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml -e ansible_user=root
```

Rerun it with the new user:

```bash
ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml
```

## Verify the Server

In a new terminal, connect to the VPS as `deployer` and confirm the configuration:

```bash
ssh deployer@<VPS_IP_ADDRESS>
whoami
timedatectl
mount | grep /srv/data
lsblk
sudo ufw status verbose
sudo sshd -t
```
