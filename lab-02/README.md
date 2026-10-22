# Terraform VPC Peering Lab: Connect VPC-A and VPC-B

Terraform code that builds two VPCs in **one AWS account and Region**, VPC-A and VPC-B, and connects them with a **VPC peering connection**. Each VPC has one small test instance. You prove the peering works by having each instance ping the other and fetch its web page over private IPs, all through Systems Manager, and then destroy everything.

> **Status:** `terraform fmt` and `terraform validate` pass (Terraform 1.16.4, AWS provider 6.69.1). The lab has not been applied yet, so the run-time behavior is described from the AWS documentation. Tell me about anything that differs.

## The Solution

![lab-02 architecture: VPC-A (10.10.0.0/16) and VPC-B (10.20.0.0/16) in one account, joined by a VPC peering connection; each VPC has a public subnet with a test instance, a route table that sends the other CIDR to the peering, and an internet gateway used only for outbound Systems Manager traffic](images/architecture.svg)

| Piece | What it does |
|-------|--------------|
| **Two VPCs** | VPC-A `10.10.0.0/16` and VPC-B `10.20.0.0/16`. The CIDRs **must not overlap**: AWS refuses to peer overlapping VPCs |
| **Peering connection** | VPC-A requests, VPC-B accepts. Both are in the same account and Region, so `auto_accept = true` makes it active at once |
| **Routes** | Peering alone carries no traffic. Each route table sends the **other** VPC's CIDR to the peering connection |
| **Remote DNS resolution** | Turned on for both sides: the other instance's **public** DNS name resolves to its **private** IP, so traffic to it stays on the peering |
| **Security groups** | Ping (ICMP) and HTTP (port 80) only from the other VPC's CIDR. Nothing from the internet |
| **Test instances** | One `t3.micro` (Amazon Linux 2023, IMDSv2, standard CPU credits) per VPC. User data serves a one-line page, for example `hello from VPC-B - 10.20.1.25` |
| **No SSH** | You run commands through **Systems Manager Run Command**. Each public subnet has an internet gateway only so the SSM agent can reach Systems Manager; no NAT gateway, no key pair |

Resources created (30): for each VPC, the VPC, internet gateway, subnet, route table and association, security group with two ingress rules and one egress rule, IAM role, policy attachment, instance profile and instance (13 each); plus the peering connection, its DNS options and the two peering routes.

Peering is **not transitive**: if VPC-B were also peered with a VPC-C, VPC-A could not reach VPC-C through VPC-B. Each pair needs its own peering connection.

## Files

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform and provider versions, the provider (Region, profile, default tags) |
| `variables.tf` | All the inputs (table below) |
| `main.tf` | The two VPC modules, the peering connection, its DNS options and the routes |
| `outputs.tf` | IDs, private addresses and ready-to-run test commands |
| `modules/vpc-with-instance/` | One VPC with a public subnet, security group, SSM role and test instance. Used twice |
| `modules/vpc-with-instance/user-data.sh.tftpl` | User data: serves the test page on port 80 with `python3 -m http.server` |

## Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `region` | `eu-west-1` | Region for both VPCs |
| `profile` | `null` | AWS CLI profile. Null uses the normal credential chain |
| `name` | `peering-lab` | Prefix of every resource name |
| `vpc_a_cidr` | `10.10.0.0/16` | CIDR of VPC-A |
| `vpc_b_cidr` | `10.20.0.0/16` | CIDR of VPC-B. Must not overlap VPC-A |
| `instance_type` | `t3.micro` | Type of the two test instances |

## Commands

### 1. Sign in

Use any case from [lab-01, step 1](../lab-01/README.md#1-sign-in-pick-the-case-that-matches-you), then set the shell variables. With a profile:

```bash
export AWS_REGION=eu-west-1
export AWS_PROFILE=<profile>
export TF_VAR_region=$AWS_REGION
export TF_VAR_profile=$AWS_PROFILE
export AWS_FLAGS="--region $AWS_REGION --profile $AWS_PROFILE"
aws sts get-caller-identity $AWS_FLAGS          # the account Terraform will change
```

Without a profile (keys in the environment, or a role on AWS), leave `AWS_PROFILE` and `TF_VAR_profile` unset and use `export AWS_FLAGS="--region $AWS_REGION"`.

### 2. Create everything

```bash
cd lab-02
terraform init
terraform plan
terraform apply
```

### 3. Check the peering

```bash
terraform output -raw peering_status_command | bash      # expect: active  10.10.0.0/16  10.20.0.0/16
terraform output vpc_a
terraform output vpc_b
```

### 4. Wait for Systems Manager

Both instances must be `Online` before Run Command can reach them, usually 1 to 3 minutes after `apply`:

```bash
aws ssm describe-instance-information $AWS_FLAGS \
  --filters Key=tag:Lab,Values=peering-lab \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table      # wait for: 2 x Online
```

### 5. Test the peering both ways

```bash
terraform output -raw test_a_to_b_command | bash      # from VPC-A to VPC-B
terraform output -raw test_b_to_a_command | bash      # from VPC-B to VPC-A
```

Each command runs four checks on one instance against the other:
1. `ping` its private IP.
2. `curl` its private IP.
3. Resolve its public DNS name with `getent hosts`.
4. `curl` that public DNS name.

What happens for A → B:

![Peering test sequence: you send a command through Systems Manager; instance A pings and curls 10.20.1.x, the route table sends it to the peering, the security group of instance B allows 10.10.0.0/16, B replies; B's public DNS name resolves to its private IP so the second curl takes the same path; the output returns to you](images/peering-test-sequence.svg)

**Expected** (A → B, addresses will differ):

```text
3 packets transmitted, 3 received, 0% packet loss
hello from VPC-B - 10.20.1.25
10.20.1.25      ec2-34-x-x-x.eu-west-1.compute.amazonaws.com
hello from VPC-B - 10.20.1.25
```

The `getent` line is the proof that remote DNS resolution works: the **public** name returns the **private** `10.20.1.x` address. B → A shows the same with `VPC-A` and `10.10.1.x`.

### 6. Break it on purpose (optional)

Delete one route and run the test again (uses `jq`): ping and both curls now time out, because VPC-A no longer knows where to send `10.20.0.0/16`, even though the peering is still `active`.

```bash
aws ec2 delete-route $AWS_FLAGS \
  --route-table-id $(terraform output -json vpc_a | jq -r .route_table_id) \
  --destination-cidr-block 10.20.0.0/16
terraform output -raw test_a_to_b_command | bash      # times out now
terraform apply                                       # puts the route back
```

### 7. Destroy everything

> **Warning: `terraform destroy` terminates both instances and deletes both VPCs and the peering. This cannot be undone.**

```bash
terraform destroy

aws ec2 describe-vpcs $AWS_FLAGS --filters Name=tag:Lab,Values=peering-lab --query 'Vpcs[].VpcId'      # expect: []
```

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `apply` fails creating the peering connection, mentioning overlapping CIDRs | The two CIDRs overlap. Pick ranges that do not, for example the defaults |
| An instance never shows `Online` in Systems Manager | No outbound route (internet gateway route missing), the role lacks `AmazonSSMManagedInstanceCore`, or the agent has not started yet. Wait a few minutes |
| Peering is `active` but ping and curl time out | A peering route is missing in one of the route tables, or a security group does not allow the other CIDR. Run `terraform apply` to restore both |
| Ping works, curl to the private IP fails | The test page is not running yet (user data still running), or port 80 is blocked. Wait a minute and retry |
| Curl to the private IP works, curl to the public DNS name times out | Remote DNS resolution is off: the name resolved to the public IP, which the security group does not allow. Check `aws_vpc_peering_connection_options` was applied |
| `InvalidInstanceId` from `send-command` | The instance is not registered with Systems Manager yet. Repeat step 4 |

## Costs and Safety

- Two `t3.micro` instances with standard credits, plus one public IPv4 address each (AWS charges for public IPv4). Together that is a few cents per hour. Peering itself has no hourly charge; traffic between the instances is in one Availability Zone, so it is free.
- **Destroy the lab when you finish.** The instances and their public IPv4 addresses keep billing until you do.
- Nothing is reachable from the internet: the security groups only allow the other VPC's CIDR.
- Use a **sandbox account**. To make the code refuse to run in another account, add `allowed_account_ids = ["<account-id>"]` to the provider block.
