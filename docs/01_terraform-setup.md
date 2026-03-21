# Terraform Setup

These steps provision the infrastructure with Terraform.

## Prerequisites

Before running Terraform, make sure you have:

- Terraform `>= 1.6.0`
- A Hetzner Cloud account and API token
- An existing SSH public key on your machine
- Your public IP address in CIDR form for SSH access, for example `203.0.113.10/32`

## `.env` Variables

This repository includes a root `.env` file with values used during setup:

- `HETZNER_API`: your Hetzner Cloud API token
- `PUBLIC_KEY_PATH`: path to your SSH public key

Terraform in `bootstrap/terraform-hcloud` does not read `.env` directly, so copy the example variables file and map the values into `terraform.tfvars` before running `plan` or `apply`.

```bash
cp bootstrap/terraform-hcloud/terraform.tfvars.example bootstrap/terraform-hcloud/terraform.tfvars
```

Set at least these values in `bootstrap/terraform-hcloud/terraform.tfvars`:

```hcl
hcloud_token        = "value-from-HETZNER_API"
ssh_public_key_path = "value-from-PUBLIC_KEY_PATH"
allowed_ssh_cidr    = "your-public-ip/32"
```

The remaining variables can usually stay at their example defaults unless you want a different server size, image, location, or volume size.

## Plan

Inspect the Terraform plan:

```bash
terraform -chdir=bootstrap/terraform-hcloud plan
```

## Apply

Apply the Terraform plan to deploy the infrastructure:

```bash
terraform -chdir=bootstrap/terraform-hcloud apply
```

## Destroy

Destroy the infrastructure when needed:

```bash
terraform -chdir=bootstrap/terraform-hcloud destroy
```
