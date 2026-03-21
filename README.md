# Home Platform

## Set up

### Minimal Set up

```bash
terraform -chdir=bootstrap/terraform-hcloud plan
terraform -chdir=bootstrap/terraform-hcloud apply
sh bootstrap/scripts/render-ansible-vars.sh
ansible-playbook -i bootstrap/ansible/inventories/prod/hosts.ini bootstrap/ansible/playbooks/harden.yml
```

### Step by step

#### Prerequisites

#### Terraform

- Inspect terraform plan

  ```bash
  terraform -chdir=bootstrap/terraform-hcloud plan
  ```

- Apply terraform plan. This will deploy the infrastructure

  ```bash
  terraform -chdir=bootstrap/terraform-hcloud apply
  ```

#### Ansible

- Generate ansible variables from terraform

  ```bash
  sh bootstrap/scripts/render-ansible-vars.sh
  ```

- Cd into `bootstrap/ansible` and ensure that file `inventories/prod/hosts.ini` has `ansible_user=root`

- Check if ansible sees the generated variables

  ```bash
  ansible-inventory -i inventories/prod/hosts.ini --host vps-prod
  ```

- Check if ansible can access the VPS

  ```bash
  ansible -i inventories/prod/hosts.ini vps -m ping -e ansible_user=root
  ```

  To remove an old key from local `known_hosts`, run:

  ```bash
  ssh-keygen -R <VPS_IP_ADDRESS>
  ssh-keygen -R vps-prod
  ```

  Then `ssh` into the VPS once to add the new host key.

- Run the playbook as root to set it up

  ```bash
  ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml -e ansible_user=root
  ```

- Rerun with new user

  ```bash
  ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml
  ```

- In a new terminal connect to VPS as `deployer`. Confirm the configuration:

  ```bash
  ssh deployer@<VPS_IP_ADDRESS>
  whoami
  timedatectl
  mount | grep /srv/data
  lsblk
  sudo ufw status verbose
  sudo sshd -t
  ```

### k3s Setup

```
ansible-playbook -i inventories/prod/hosts.ini playbooks/k3s.yml
```

## Destroy infra

```bash
terraform -chdir=bootstrap/terraform-hcloud destroy
```
