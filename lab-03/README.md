# Terraform AMI Lab: Back Up an EC2 Instance and Restore It in a Second Region

Terraform code that backs up an EC2 instance as an **Amazon Machine Image (AMI)**, **copies the AMI to a secondary Region**, and **launches a new instance from the copy** there. A marker file written on the source instance shows up unchanged on the restored one, which proves the data came across. You check both instances through Systems Manager, then destroy everything.

> **Status:** `terraform fmt` and `terraform validate` pass (Terraform 1.16.4, AWS provider 6.70.0, time provider 0.14.2). The lab has not been applied yet, so the run-time behavior is described from the AWS documentation. Tell me about anything that differs.

## The Solution

![lab-03 architecture: in the primary Region (eu-west-1) a source instance is backed up as an AMI; the AMI is copied to the secondary Region (eu-central-1), where a restored instance is launched from the copy; one global IAM instance profile is used in both Regions and Systems Manager reaches the instances without SSH](images/architecture.svg)

| Piece | What it does |
|-------|--------------|
| **Source instance** | `t3.micro`, Amazon Linux 2023, in the primary Region's default VPC. User data writes `/etc/ami-lab-marker` (instance ID, Region, time) and installs a small `ami-lab-whereami` script |
| **AMI (backup)** | `aws_ami_from_instance`: an EBS snapshot of the root volume plus the launch settings. EC2 **reboots** the instance first so the file system is consistent (`snapshot_without_reboot = false`) |
| **AMI copy** | `aws_ami_copy` to the secondary Region. The copy gets a **new AMI ID** and its own snapshot, encrypted with that Region's default EBS key (`aws/ebs`). Terraform waits until it is `available`, which takes several minutes |
| **Restored instance** | A new instance in the secondary Region's default VPC, launched from the copy. It has the marker file from the source, but its own instance ID |
| **IAM** | One role and instance profile with `AmazonSSMManagedInstanceCore`. IAM is global, so both Regions use the same profile |
| **No SSH** | Security groups with **no inbound rules**. You run commands through **Systems Manager Run Command** in each Region |

Resources created (12): in the primary Region a security group and egress rule, the source instance and the AMI; in the secondary Region a security group and egress rule, the AMI copy and the restored instance; the IAM role, policy attachment and instance profile; and a 90-second wait (`time_sleep`) so user data finishes before the image is taken.

An AMI is a **point-in-time** backup: anything written on the source after the image is taken is not in it.

## Files

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform and provider versions, and the two AWS providers: primary Region and `secondary` |
| `variables.tf` | All the inputs (table below) |
| `main.tf` | Default VPCs, security groups, IAM, source instance, AMI, AMI copy and restored instance |
| `outputs.tf` | IDs and ready-to-run check commands |
| `user-data.sh` | Writes the marker file and the `ami-lab-whereami` script on the source instance |

## Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `region` | `eu-west-1` | Primary Region: source instance and AMI |
| `secondary_region` | `eu-central-1` | Secondary Region: AMI copy and restored instance. Must differ from `region` |
| `profile` | `null` | AWS CLI profile for both Regions. Null uses the normal credential chain |
| `name` | `ami-lab` | Prefix of every resource name |
| `instance_type` | `t3.micro` | Type of the source and the restored instance |
| `encrypt_copy` | `true` | Encrypt the copy's snapshot with the secondary Region's default EBS key |
| `restore` | `true` | Launch the restored instance. `false` stops after the copy |

## Commands

### 1. Sign in

Use any case from [lab-01, step 1](../lab-01/README.md#1-sign-in-pick-the-case-that-matches-you), then set the shell variables. With a profile:

```bash
export AWS_REGION=eu-west-1
export AWS_SECONDARY_REGION=eu-central-1
export AWS_PROFILE=<profile>
export TF_VAR_region=$AWS_REGION
export TF_VAR_secondary_region=$AWS_SECONDARY_REGION
export TF_VAR_profile=$AWS_PROFILE
export AWS_FLAGS="--region $AWS_REGION --profile $AWS_PROFILE"
export AWS_FLAGS_2="--region $AWS_SECONDARY_REGION --profile $AWS_PROFILE"
aws sts get-caller-identity $AWS_FLAGS          # the account Terraform will change
```

Without a profile, leave `AWS_PROFILE` and `TF_VAR_profile` unset and drop `--profile` from both flag variables.

Both Regions need a **default VPC**. Check with:

```bash
aws ec2 describe-vpcs $AWS_FLAGS   --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-vpcs $AWS_FLAGS_2 --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text
```

`None` means there is none: create one with `aws ec2 create-default-vpc` and the same flags.

### 2. Create everything

```bash
cd lab-03
terraform init
terraform plan
terraform apply
```

The apply runs in this order and takes about **10 to 20 minutes**, most of it the copy:

![Backup and restore sequence: Terraform launches the source instance, whose user data writes the marker; after a 90-second wait it creates the AMI (the instance reboots), copies it to eu-central-1 (several minutes, encrypted), and launches the restored instance from the copy; you then read the marker through Systems Manager and it names the source instance in eu-west-1](images/backup-restore-sequence.svg)

### 3. Look at the two AMIs

```bash
terraform output -raw images_command | bash
```

**Expected**: two lines, each `available`, with **different** AMI IDs and **different** snapshot IDs. The last column is `False` for the original (unless your account encrypts EBS by default) and `True` for the copy.

### 4. Check the source and the restored instance

Wait until both instances are `Online` in Systems Manager (1 to 3 minutes after they start):

```bash
aws ssm describe-instance-information $AWS_FLAGS   --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
aws ssm describe-instance-information $AWS_FLAGS_2 --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
```

Then:

```bash
terraform output -raw check_source_command | bash
terraform output -raw check_restored_command | bash
```

**Expected** (IDs and times will differ):

```text
# source, eu-west-1
created on i-0aaa1111 in eu-west-1 at 2026-10-22T09:00:12Z
running on i-0aaa1111 in eu-west-1 from ami-0al2023xxxx

# restored, eu-central-1
created on i-0aaa1111 in eu-west-1 at 2026-10-22T09:00:12Z
running on i-0bbb2222 in eu-central-1 from ami-0copyxxxx
```

The first line is identical on both: the marker was written on the source in eu-west-1 and travelled inside the AMI. The second line shows the restored instance is a different instance, in eu-central-1, running the copied AMI.

### 5. Show that the backup is point-in-time (optional)

Write a file on the source **after** the backup, then look for it on the restored instance:

```bash
SRC=$(terraform output -raw source_instance_id)
DST=$(terraform output -raw restored_instance_id)

aws ssm send-command $AWS_FLAGS --instance-ids $SRC --document-name AWS-RunShellScript \
  --parameters 'commands=["echo after-backup > /etc/ami-lab-after"]' --query Command.CommandId --output text

CMD=$(aws ssm send-command $AWS_FLAGS_2 --instance-ids $DST --document-name AWS-RunShellScript \
  --parameters 'commands=["ls /etc/ami-lab-after"]' --query Command.CommandId --output text)
aws ssm wait command-executed $AWS_FLAGS_2 --command-id "$CMD" --instance-id $DST || true
aws ssm get-command-invocation $AWS_FLAGS_2 --command-id "$CMD" --instance-id $DST \
  --query StandardErrorContent --output text      # expect: No such file or directory
```

To take a new backup and restore it again, replace the AMI. Terraform then also replaces the copy and the restored instance, because both depend on it:

```bash
terraform apply -replace=aws_ami_from_instance.backup
```

### 6. Destroy everything

> **Warning: `terraform destroy` terminates both instances, deregisters both AMIs and deletes their snapshots. This cannot be undone.**

```bash
BACKUP=$(terraform output -raw backup_ami_id)      # note both IDs before destroying
COPY=$(terraform output -raw copy_ami_id)
terraform destroy

aws ec2 describe-images $AWS_FLAGS   --image-ids $BACKUP --query 'Images[].ImageId'      # expect: [] or InvalidAMIID.NotFound
aws ec2 describe-images $AWS_FLAGS_2 --image-ids $COPY   --query 'Images[].ImageId'      # expect: [] or InvalidAMIID.NotFound
aws ec2 describe-snapshots $AWS_FLAGS   --owner-ids self --filters "Name=description,Values=*$BACKUP*" --query 'Snapshots[].SnapshotId'      # expect: []
aws ec2 describe-snapshots $AWS_FLAGS_2 --owner-ids self --filters "Name=description,Values=*$COPY*"   --query 'Snapshots[].SnapshotId'      # expect: []
```

The snapshot descriptions name their AMI (`Created by CreateImage(...) for ami-...` and `Copied for DestinationAmi ami-...`), which is how the last two commands find them.

Snapshots left over after destroy keep billing. Delete any that belong to the lab's AMIs with `aws ec2 delete-snapshot`.

## The same with the AWS CLI

What Terraform does, by hand:

```bash
# 1. Back up: create the AMI (reboots the instance) and wait for it
AMI=$(aws ec2 create-image $AWS_FLAGS --instance-id <source-instance-id> --name ami-lab-manual --query ImageId --output text)
aws ec2 wait image-available $AWS_FLAGS --image-ids $AMI

# 2. Copy it to the secondary Region (the command runs in the DESTINATION Region)
COPY=$(aws ec2 copy-image $AWS_FLAGS_2 --source-region $AWS_REGION --source-image-id $AMI \
  --name ami-lab-manual --encrypted --query ImageId --output text)
aws ec2 wait image-available $AWS_FLAGS_2 --image-ids $COPY

# 3. Restore: launch an instance from the copy
aws ec2 run-instances $AWS_FLAGS_2 --image-id $COPY --instance-type t3.micro \
  --iam-instance-profile Name=ami-lab-ssm --metadata-options HttpTokens=required
```

Resources made this way are not in Terraform state: deregister the AMIs, delete their snapshots and terminate the instance yourself.

## Beyond the lab

For real backups, schedule them instead of running Terraform by hand: **AWS Backup** (a backup plan with a copy rule to the secondary Region) or **Amazon Data Lifecycle Manager** (an EBS-backed AMI policy with cross-Region copy) create, copy and expire AMIs on a schedule.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `no matching EC2 VPC found` | A Region has no default VPC. Create it with `aws ec2 create-default-vpc` (step 1) |
| `secondary_region must be different from region` | Both variables name the same Region. Pick another secondary Region |
| The copy is still `pending` after 20 minutes | Large or busy copies can take longer. Terraform waits up to 40 minutes; check progress with the `images_command` output |
| The marker file is missing on the source | The image was taken before user data finished. Recreate with `terraform apply -replace=aws_instance.source` |
| The restored instance never shows `Online` | The default subnet in the secondary Region has no route to the internet, or the agent is still starting. Wait a few minutes |
| `InvalidAMIID.NotFound` with the CLI commands | The AMI ID belongs to the other Region. Use `$AWS_FLAGS` for the original and `$AWS_FLAGS_2` for the copy |
| Launch fails with a KMS error on the copy | Your account uses a customer managed default EBS key the role cannot use. Set `encrypt_copy=false`, or grant access to the key |

## Costs and Safety

- Two `t3.micro` instances with standard credits and a public IPv4 address each, two 8 GiB EBS root volumes, two EBS snapshots (one per Region), and the **cross-Region data transfer** of the copy (a few GB). Together that is a few cents per hour while it runs.
- **Destroy the lab when you finish.** Snapshots keep billing as long as they exist, even with the instances gone.
- Nothing is reachable from the internet: the security groups have no inbound rules.
- Use a **sandbox account**. To make the code refuse to run in another account, add `allowed_account_ids = ["<account-id>"]` to both provider blocks.
