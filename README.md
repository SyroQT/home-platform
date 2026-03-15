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

  `terraform -chdir=bootstrap/terraform-hcloud plan`

- Apply terraform plan. This will deploy the infrastructure

  `terraform -chdir=bootstrap/terraform-hcloud plan`

#### Ansible

- Generate ansible variables from terraform

  `sh bootstrap/scripts/render-ansible-vars.sh`

- Cd into `bootstrap/ansible` and ensure that file `inventories/prod/hosts.ini` has `ansible_user=root`

- Check if ansible sees the generated variables

  `ansible-inventory -i inventories/prod/hosts.ini --host vps-prod`

- Check if ansible can access the VPS

  `ansible -i inventories/prod/hosts.ini vps -m ping`

  To remove old old key from local known_hosts: `ssh-keygen -R <VPS_IP_ADDRESS>`, then `ssh` into to add to the list of known host
  `

- Run the playbook as root

  `ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml -u root`

- Rerun with new user

  `ansible-playbook -i inventories/prod/hosts.ini playbooks/harden.yml`

- In a new terminal connect to VPS as `deployer`. Confirm the configuration:

  ```bash
  whoami
  timedatectl
  mount | grep /srv/data
  lsblk
  sudo ufw status verbose
  sudo sshd -t
  ```

## Destroy infra

`terraform -chdir=bootstrap/terraform-hcloud destroy`
