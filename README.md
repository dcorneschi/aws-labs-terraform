# AWS Labs with Terraform

Hands-on AWS labs, each built with Terraform. Every lab lives in its own folder with its own Terraform configuration and a README that explains the design, the inputs and the commands to run it step by step.

## Labs

| Lab | What it builds |
|-----|----------------|
| [lab-01](lab-01/README.md) | An Auto Scaling group of Spot instances that adds a second instance when the group's average CPU reaches 75%. You raise the CPU through Systems Manager, watch the scale-out, then destroy everything |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) (the labs are tested with 1.16.x)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), signed in to an account where you can create the resources (for example with `aws login` or `aws sso login --profile <name>`)
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for labs that connect to instances without SSH

## Running a lab

```bash
cd lab-01
terraform init
terraform plan
terraform apply
```

Follow the lab's README for the steps in between, and always finish with:

```bash
terraform destroy
```

> **Cost:** the labs create real, billable AWS resources. Destroy them when you are done.

## Repository layout

```text
.
├── .gitignore    # Terraform ignores shared by every lab (state, .terraform/, lock files, tfvars, plans)
├── README.md
└── lab-01/       # one folder per lab, each a standalone Terraform root module
```

State is kept locally in each lab folder and is never committed. Neither is `.terraform.lock.hcl`: `terraform init` creates it with the newest provider version allowed by each lab's `versions.tf`.
