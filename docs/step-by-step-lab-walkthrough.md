# My Project 1B proactive Linux hardening journey

I wanted to build a private file-transfer server, restrict what its transfer account could do, and prove that the restrictions worked. My demonstration used `mds-sftp-test.txt`, a small text file containing `SFTP hardening lab transfer test`. I uploaded it, downloaded it, and compared the hashes. I then destroyed the AWS lab with Terraform.

This walkthrough follows the dependencies from the beginning. I explain each tool before using it, identify the terminal for each command, and give a checkpoint before the next phase. The commands provide a follow-along route using this repository; my journal results are identified as results from my run. Conditional installation steps are there for a fresh workstation.

| Layer | Sequence |
| --- | --- |
| 1. AWS infrastructure | Understand automation → prepare WSL → check/install tools → authenticate to AWS → get the project files → inspect AWS → define infrastructure → plan and deploy |
| 2. Access management and SSH hardening | Confirm SSM connectivity → inspect the target → prepare its disk → prepare the Ansible controller → stage the public key and configuration → review the access policy → apply and check it |
| 3. Linux operating system hardening | Check packages and updates → inspect AppArmor → verify the host firewall → load and test audit rules → verify kernel settings → review host health |
| 4. Validation and cleanup | Verify the server identity → transfer the text file → test denied actions → retain evidence → destroy resources → check the result |

**Starting point:** Ubuntu in WSL is already available on my Windows workstation, and I have authorized access to an AWS account where I can create a lab. Open the Ubuntu terminal for Linux commands. Do not paste the `$` or `sftp>` prompt when entering commands; those indicate which shell is in use. Run one block at a time and resolve errors before continuing.

## 1. AWS infrastructure layer

### 1.1 Why I started with automation, then checked my local WSL environment

Automation is central to DevSecOps because I need changes I can review, repeat, and remove reliably. I chose **Infrastructure as Code (IaC)** for the AWS resources: describe the desired infrastructure in files, review a proposed change, and let Terraform create it consistently. Later, Ansible would configure the Linux server. Terraform and Ansible have different jobs, so I prepared Terraform first.

Before touching AWS, I needed to know which Linux environment and user I was working in.

**Run in: local WSL Ubuntu.**

```bash
whoami
hostname
cat /etc/os-release
uname -r
```

`whoami` identifies my local Linux user, `hostname` identifies the machine, and the last two commands identify the operating system and kernel. My workstation reported a Microsoft WSL2 kernel. This was my local computer; no EC2 instance existed yet.

I initially worked as root. I created an ordinary account so routine commands would run without full Linux privileges, with `sudo` available when necessary. **Run this next block only if you are currently root and the `devsecops` account does not already exist.** If you already have a normal sudo-enabled WSL account, keep using it.

```bash
adduser devsecops
usermod -aG sudo devsecops
id devsecops
su - devsecops
```

`adduser` asks for a local password. `usermod -aG sudo` adds sudo membership while keeping existing groups. `su -` switches to that user's login environment.

```bash
whoami
sudo whoami
```

**Checkpoint:** the first command identifies my ordinary account; the second returns `root` after elevation. This Linux account is separate from the AWS identity I will configure later.

### 1.2 I checked Terraform and AWS CLI before trying to use them

**Run in: local WSL, as the ordinary user.**

```bash
terraform version
aws --version
command -v terraform
command -v aws
```

Terraform manages the infrastructure files. The AWS Command Line Interface (CLI) lets me authenticate and query AWS from the terminal. The version commands show whether they run; `command -v` shows which executable the shell finds.

My Terraform check returned version `1.16.6`. AWS CLI was available under a different user but initially returned `command not found` for `devsecops`. I learned that installing a tool under root does not make a user-local installation available to every account.

First I prepared the small utilities used by the following setup steps:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release git python3 openssh-client
```

`apt-get update` refreshes the package index; it does not upgrade every installed package. Git will download this repository, Python will help with local configuration, and the OpenSSH client provides `ssh`, `sftp`, and `ssh-keygen`.

**Only if Terraform is missing:** the following uses HashiCorp's signed Ubuntu package repository. If the repository does not support your Ubuntu release, stop at that error and use the matching package from the [official Terraform installation guide](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli).

```bash
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null

gpg --show-keys --fingerprint /usr/share/keyrings/hashicorp-archive-keyring.gpg

. /etc/os-release
printf 'deb [arch=%s signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com %s main\n' \
  "$(dpkg --print-architecture)" "${UBUNTU_CODENAME:-$VERSION_CODENAME}" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update
sudo apt-get install -y terraform
terraform version
```

The keyring allows APT to authenticate packages from that repository. The distribution codename selects packages for this Ubuntu release. Terraform was already installed in my lab; this conditional block fills the prerequisite for someone starting fresh.

**Only if AWS CLI is missing:** I used AWS's user-local installation method. The [AWS installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) describes this installer, its verification, and its update options.

```bash
mkdir -p "$HOME/.local/tmp/project-1b-tools"
curl -fsSL https://awscli.amazonaws.com/v2/install.sh \
  -o "$HOME/.local/tmp/project-1b-tools/awscli-install.sh"
bash "$HOME/.local/tmp/project-1b-tools/awscli-install.sh"
export PATH="$HOME/.local/bin:$PATH"
aws --version
```

My installation reported AWS CLI `2.38.3`. The executable was under `~/.local/bin`, so I made that location available in new Bash sessions as well:

```bash
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc \
  || printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
terraform version
aws --version
```

**Checkpoint:** both version commands work as my ordinary WSL user. I have installed tools, but I have not yet authenticated to AWS or created any resources.

### 1.3 I established an AWS identity before using a named profile

Having `aws` installed does not grant access to an AWS account. My first identity check returned `NoCredentials`. I needed an authorized AWS identity, a sign-in method, and a local profile that selected it.

A **profile** is a named AWS CLI configuration. The Linux user `devsecops`, the IAM user `mds-devsecops-lab`, and the CLI profile `mds-devsecops-lab` are different things even though two names match.

For my lab, I created a dedicated IAM user, enabled console access and MFA, then used browser-based `aws login` to obtain temporary CLI credentials. If your organization already provides an authorized IAM Identity Center role, use that existing access and its profile instead of creating a second IAM identity.

<details>
<summary>One-time setup: create the lab IAM user if it does not already exist</summary>

**Run in: local WSL, authenticated as an existing authorized AWS administrator.** This is account bootstrap, before signing in as the new user. Choose the administrator identity in the browser and verify it locally:

```bash
aws login --profile lab-bootstrap
aws sts get-caller-identity --profile lab-bootstrap
```

The following commands create the IAM user and attach the two policies used in my lab:

```bash
aws iam create-user --user-name mds-devsecops-lab \
  --profile lab-bootstrap --query User.UserName --output text

aws iam attach-user-policy --user-name mds-devsecops-lab \
  --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess \
  --profile lab-bootstrap

aws iam attach-user-policy --user-name mds-devsecops-lab \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
  --profile lab-bootstrap

aws iam list-attached-user-policies --user-name mds-devsecops-lab \
  --profile lab-bootstrap
```

`SignInLocalDevelopmentAccess` enables the browser sign-in flow. It does not itself authorize EC2 or S3 actions. My human lab user had the broad `AdministratorAccess` policy for provisioning; this is a lab permission choice, and I did not give it to either server. A team deployment should use its approved deployment role and permission scope.

Before signing in as this user, I completed its console credentials and MFA setup. In the AWS console, open **IAM → Users → mds-devsecops-lab → Security credentials**. Enable console access, set the initial password and required reset, and assign an authenticator MFA device. Scan the QR image privately, enter two successive codes, and verify the device is attached. Then sign in as the new IAM user, complete the password reset, and confirm MFA works. These steps must be completed before the next CLI login; creating an IAM user alone does not give it a console password.

```bash
aws iam list-mfa-devices --user-name mds-devsecops-lab \
  --query 'length(MFADevices)' --output text --profile lab-bootstrap
```

My result was `1`. I kept the password, QR image, seed, and one-time codes out of the journal and repository. Once finished with the bootstrap identity, I signed it out:

```bash
aws logout --profile lab-bootstrap
```

</details>

**Run in: local WSL, after the intended AWS identity is ready.**

```bash
aws login --profile mds-devsecops-lab
aws configure set region us-east-1 --profile mds-devsecops-lab
aws sts get-caller-identity --profile mds-devsecops-lab
aws configure get region --profile mds-devsecops-lab
```

I selected my lab IAM user in the browser. `get-caller-identity` then confirmed the principal, and the Region check returned `us-east-1`. I checked the full identity locally rather than publishing account details.

**Problem I encountered:** console sign-in worked before the named CLI profile existed. The CLI therefore returned “The config profile could not be found.” Creating/authenticating that profile with `aws login --profile mds-devsecops-lab` resolved the missing-profile step. An expired CLI session later needs a new login; it is different from an expired IAM console password.

To make the next AWS commands use the same profile and Region in this terminal:

```bash
export AWS_PROFILE=mds-devsecops-lab
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity
```

**Checkpoint:** I know which AWS account, principal, and Region the commands will use. No infrastructure has been created yet.

### 1.4 I obtained the project files before running Terraform

**Run in: local WSL.** For a fresh reproduction, download the repository once:

```bash
cd ~
git clone https://github.com/DelaneKay/project-01b-proactive-linux-hardening.git
cd ~/project-01b-proactive-linux-hardening
ls
ls terraform
```

If it is already cloned, use the existing directory and skip `git clone`. The repository root contains `terraform/`, `ansible/`, `docs/`, and `evidence/`. The original working folder in my journal was named `mds-aws-linux-hardening-1b`; the commands in this guide consistently use the clone directory above.

Terraform reads all `.tf` files in its working directory together. A file such as `network.tf` is a piece of the configuration, not a script to run independently. At this point I only have the code locally; downloading it creates nothing in AWS.

### 1.5 I inspected AWS before choosing the lab's network, image, and storage

I had working tools, credentials, and source files. Next I needed facts to inform the design: an unused network range, a supported Availability Zone and instance size, the intended Ubuntu image, and the account's storage-encryption default.

**Run in: local WSL, with the profile from Phase 1.3. These are read-only queries.**

```bash
# Check existing VPC ranges to avoid overlap with the proposed lab VPC.
aws ec2 describe-vpcs \
  --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Default:IsDefault}' \
  --output table --profile "$AWS_PROFILE" --region us-east-1

# Check AZs and confirm the chosen EC2 sizes are offered in the selected AZ.
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[].ZoneName' --output table \
  --profile "$AWS_PROFILE" --region us-east-1
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=location,Values=us-east-1a Name=instance-type,Values=t3.micro,t3.small \
  --query 'InstanceTypeOfferings[].InstanceType' --output table \
  --profile "$AWS_PROFILE" --region us-east-1

# Resolve Canonical's current Ubuntu 24.04 x86-64 gp3 AMI, then verify its metadata.
AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text \
  --profile "$AWS_PROFILE" --region us-east-1)"
aws ec2 describe-images --image-ids "$AMI_ID" \
  --query 'Images[].{ImageId:ImageId,Name:Name,OwnerId:OwnerId,Architecture:Architecture,State:State,RootDeviceType:RootDeviceType}' \
  --output table --profile "$AWS_PROFILE" --region us-east-1

# Inspect defaults; Terraform still explicitly sets encrypted = true.
aws ec2 get-ebs-encryption-by-default \
  --profile "$AWS_PROFILE" --region us-east-1
aws ec2 get-ebs-default-kms-key-id \
  --profile "$AWS_PROFILE" --region us-east-1
```

The VPC query showed my existing default VPC used `172.31.0.0/16`, so I chose `10.20.0.0/16` for the lab. The AZ/type checks supported the selected `us-east-1a`, `t3.small`, and `t3.micro` combination. I verified the image was available, `x86_64`, and owned by Canonical (`099720109477`). Its ID can change as Ubuntu publishes images; [ami.tf](../terraform/ami.tf) performs the SSM parameter lookup for deployment.

The EBS default-encryption query returned `false`; the default key was `alias/aws/ebs`. I therefore explicitly enabled encryption on my project volumes in [compute.tf](../terraform/compute.tf), rather than relying on an account default. Encryption protects stored volume data, while Linux permissions will control what a logged-in user can access.

**Problem I encountered:** my first VPC query returned `OptInRequired`. I paused instead of guessing a network range. A later retry returned the default VPC successfully; I did not establish a definite cause for the earlier error.

**Checkpoint:** the chosen CIDRs, AZ, instance sizes, and image are supported in the account. If your results differ, adjust the input values in Phase 1.7 before planning.

### 1.6 I translated those checks into the AWS design and Terraform files

Only now did I have enough information to settle the deployment. I needed three machines with clear responsibilities: my existing WSL workstation would run Terraform and AWS CLI; a private admin EC2 would run Ansible; a private target EC2 would host SFTP.

I chose Session Manager for administration because it uses an IAM-authorized session and the instance agent's outbound connection. That let me keep both EC2 nodes without public IPs or inbound SSH rules. I considered a public bastion, but it would add another server to patch and monitor. OpenSSH would still run on the target for SFTP, reached through a later SSM tunnel.

```text
Operator workstation (WSL: Terraform + AWS CLI)
       | SSM Session Manager
       +-------------------------> Private admin EC2 (t3.small, Ansible)
       |                                   |
       |                                   | Ansible amazon.aws.aws_ssm
       |                                   | SSM channels + temporary S3 transfer
       |                                   v
       +-- SSM port forwarding ------> Private target EC2 (t3.micro, Ubuntu 24.04.5)
                                           | local OpenSSH/SFTP :22
                                           | no inbound SG rules
                                           +-- encrypted 5 GiB EBS data volume
                                               /srv/sftp-data/upload

Private subnet egress -> one public-subnet NAT Gateway -> Internet
Private S3 transfer bucket -> S3 Gateway VPC endpoint
```

| Decision | Value I chose | Why it matters | Terraform implementation |
| --- | --- | --- | --- |
| Network | VPC `10.20.0.0/16`; NAT/public `10.20.0.0/24`; private admin `10.20.10.0/24`; private target `10.20.20.0/24` | Separate routing roles and avoid the existing VPC range | [network.tf](../terraform/network.tf) |
| Outbound access | One NAT Gateway; S3 Gateway endpoint on private route tables | Package/SSM traffic needs egress; S3 transfers use the endpoint | [network.tf](../terraform/network.tf) |
| Network access rules | No inbound rules; outbound HTTPS | Keep management off public SSH and allow required HTTPS services | [security-groups.tf](../terraform/security-groups.tf) |
| Compute | Ubuntu 24.04 LTS; `t3.small` admin and `t3.micro` target | Give Ansible a larger controller while keeping the target small | [ami.tf](../terraform/ami.tf), [compute.tf](../terraform/compute.tf) |
| Storage | Encrypted 20-GiB gp3 roots and separate encrypted 5-GiB target data disk | Explicit encryption and separation of transfer data from the OS | [compute.tf](../terraform/compute.tf) |
| Metadata | IMDSv2 required | Require session tokens for instance metadata requests | [compute.tf](../terraform/compute.tf) |
| Instance identities | Separate admin/target roles; minimal agent actions and scoped controller permissions | Limit each server's AWS permissions to its duties | [iam.tf](../terraform/iam.tf) |
| Transfer storage | Private encrypted S3 bucket, HTTPS-only policy, temporary-object cleanup | Stage Ansible files and the SFTP public key | [s3.tf](../terraform/s3.tf) |

A private subnet still needs a route for permitted outbound traffic. My private route tables send general egress to the NAT Gateway; its public subnet routes to the Internet Gateway. An S3 prefix-list route sends S3 traffic through the gateway endpoint. The endpoint policy and IAM permissions still apply. The endpoint itself is defined in `network.tf`, while the bucket and its policy are in `s3.tf`.

The security groups permit outbound TCP 443. The instance bootstrap in `compute.tf` changes Ubuntu package sources to HTTPS so package installation fits that policy. If package updates fail, I inspect repository URLs and connectivity before broadening the rules.

Before deployment, I also reviewed the instance permissions. My human AWS account could provision resources; the servers did not need that privilege. Both agents needed these five SSM actions:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel"
    ],
    "Resource": "*"
  }]
}
```

The admin role additionally needed permission to start a session to the target and use the lab transfer bucket. Ansible's SSM connection stages temporary module files in S3. I scoped the controller's S3 actions to that bucket and its objects. The target downloads short-lived presigned URLs, so network access to S3 is required even without separate target S3 credentials. This is described in the [Ansible SSM connection documentation](https://docs.ansible.com/projects/ansible/latest/collections/amazon/aws/aws_ssm_connection.html).

I chose one managed NAT Gateway because it saved me operating another Linux server. The single-AZ design was appropriate for this temporary exercise. My journal estimated about `$32.85/month` for continuous NAT usage and `$22.85/month` for the two instances before other charges. Those were planning estimates, not current quotes. My budget alert was a notification, so teardown was part of the plan from the beginning.

**Checkpoint:** I can explain the purpose of each resource and its permission boundary before creating it.

### 1.7 I set the inputs, initialized Terraform, and reviewed the plan

**Run in: local WSL.**

```bash
cd ~/project-01b-proactive-linux-hardening/terraform
cp -n terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

`cp -n` creates my local input file without replacing an existing one. In Nano, I review or edit the values, save with `Ctrl+O`, press Enter, and exit with `Ctrl+X`. The example values are in [terraform.tfvars.example](../terraform/terraform.tfvars.example), and their meanings are declared in [variables.tf](../terraform/variables.tf). Keep `availability_zone` in the configured Region and use the CIDRs checked earlier.

```bash
aws sts get-caller-identity
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=lab.tfplan
```

[versions.tf](../terraform/versions.tf) declares the AWS provider. `init` installs it and initializes the directory; `fmt -check` checks formatting; `validate` checks the configuration; and `plan` asks AWS about the current state and proposes changes. The saved plan is the exact proposal I will apply. If formatting fails, run `terraform fmt -recursive`, review the changes, and repeat the check.

I read the whole plan for Region, addresses, IAM permissions, volume encryption, public IP assignment, and ingress rules. I expected new lab resources, no unexpected deletion, encrypted volumes, and no public EC2 addresses. A successful validation does not mean the architecture is secure; that is why I reviewed the values.

**Checkpoint:** the checks pass and I understand the saved plan. Keep state, local variable files, and plan files out of public commits; they can contain account-specific or sensitive data.

### 1.8 I deployed the reviewed plan and saved the identifiers for later phases

**Run in: local WSL, still in the `terraform/` directory.** Applying creates billable AWS resources.

```bash
terraform apply lab.tfplan
terraform output
```

The outputs are declared in [outputs.tf](../terraform/outputs.tf). I need the two instance IDs and bucket name for the next phases, so I capture them only after apply succeeds:

```bash
ADMIN_ID="$(terraform output -raw admin_instance_id)"
TARGET_ID="$(terraform output -raw target_instance_id)"
TRANSFER_BUCKET="$(terraform output -raw ansible_transfer_bucket)"

mkdir -p "$HOME/.local/state/project-01b"
(
  umask 077
  printf 'export AWS_PROFILE=%q\n' "$AWS_PROFILE"
  printf 'export AWS_REGION=%q\n' "$AWS_REGION"
  printf 'export AWS_DEFAULT_REGION=%q\n' "$AWS_REGION"
  printf 'export ADMIN_ID=%q\n' "$ADMIN_ID"
  printf 'export TARGET_ID=%q\n' "$TARGET_ID"
  printf 'export TRANSFER_BUCKET=%q\n' "$TRANSFER_BUCKET"
) > "$HOME/.local/state/project-01b/lab.env"
chmod 600 "$HOME/.local/state/project-01b/lab.env"
source "$HOME/.local/state/project-01b/lab.env"
cd ~/project-01b-proactive-linux-hardening
```

This local file stores identifiers and profile selection, not passwords or access keys. It also keeps the bucket name available if a partial destroy later removes Terraform outputs. In **each new WSL terminal** from now on, run:

```bash
source "$HOME/.local/state/project-01b/lab.env"
cd ~/project-01b-proactive-linux-hardening
```

**Checkpoint:** Terraform has completed, the output values exist, and the local environment file is ready. Layer 1 is complete; I can now connect to the servers that were just created.

## 2. Access management and SSH hardening

### 2.1 I checked Session Manager prerequisites before opening a session

AWS resources existing does not mean I can manage them yet. Session Manager needs an agent on the instance, suitable IAM permissions and outbound connectivity, and a client plugin on my workstation.

**Run in: local WSL.**

```bash
source "$HOME/.local/state/project-01b/lab.env"
command -v session-manager-plugin
session-manager-plugin --version
```

**Only if the plugin is missing, on x86_64 Ubuntu:**

```bash
uname -m
curl -fL https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb \
  -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
session-manager-plugin --version
```

Use the matching ARM package from the [AWS plugin installation guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-debian-and-ubuntu.html) if `uname -m` reports ARM. My T3 instances and WSL lab used x86_64.

Next I checked whether both instances had registered with SSM:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$ADMIN_ID,$TARGET_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus,OS:PlatformName}' \
  --output table
```

**Checkpoint:** both IDs appear with `Online`. A new instance can take a few minutes to register. If one is missing, check the instance profile, agent, NAT route, DNS, and HTTPS egress; I do not add public SSH to conceal an SSM setup problem.

### 2.2 I opened a target session and captured its starting state

I kept separate terminals for WSL, the target, and later the admin controller. A command that checks the wrong host can give a perfectly valid but irrelevant answer.

**Run in: local WSL, in a new terminal after loading `lab.env`.**

```bash
aws ssm start-session --target "$TARGET_ID"
```

The prompt now belongs to the target EC2. **Run the following inside that target session:**

```bash
hostname
whoami
cat /etc/os-release
uname -r
sudo ss -lntup
systemctl list-units --type=service --state=running --no-pager
command -v curl
python3 --version
```

My target was Ubuntu 24.04.5 on an AWS kernel. If this check shows `microsoft-standard-WSL2`, I am still on the workstation. I made that mistake during the lab and corrected it before interpreting missing packages or firewall output. The target needs `curl` and Python for the Ansible path; if either is missing, install them with `sudo apt-get update` followed by `sudo apt-get install -y curl python3` here.

SSH listened on local port 22, alongside resolver and time-service sockets. That inventory tells me which programs listen; reachability also depends on AWS network controls. I recorded this baseline before changing the account or SSH policy.

**Checkpoint:** I have positively identified the target and it has the basic Ansible dependencies. Leave this target session open.

### 2.3 I prepared the dedicated data filesystem before configuring the chroot

The 5-GiB disk created by Terraform is a block device. SFTP needs a mounted filesystem. I chose `/srv/sftp-data` as the server-side storage location and future chroot root. A **chroot** gives the SFTP account a restricted filesystem view; its `/` will represent this directory.

**Run in: target SSM session.** Inspect first:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS,SERIAL
sudo blkid
findmnt /
```

Identify the separate 5-GiB EBS volume, matching its serial/volume identity to the attached data volume if needed. My device appeared as `/dev/nvme1n1`; device numbering can change. The commands below are a repeatable preparation example for a **new, empty lab data volume**, not commands to rerun on an existing filesystem. My journal confirms the ext4/UUID mount outcome but does not preserve every original disk command.

Only after confirming the intended data device is blank and is not the OS disk, enter its path:

```bash
read -r -p 'Verified empty data-device path: ' DATA_DEVICE
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS "$DATA_DEVICE"
```

Review that output before the next block. `mkfs.ext4` creates a filesystem and destroys any existing filesystem on that device.

```bash
sudo mkfs.ext4 "$DATA_DEVICE"
sudo install -d -o root -g root -m 0755 /srv/sftp-data
sudo blkid "$DATA_DEVICE"
grep -nF '/srv/sftp-data' /etc/fstab || true
sudo nano /etc/fstab
```

If there is no existing entry for this mount, add one line, replacing the placeholder with the UUID just returned by `blkid`:

```text
UUID=REPLACE_WITH_FILESYSTEM_UUID /srv/sftp-data ext4 defaults,nofail 0 2
```

Save and exit Nano. UUID identifies the filesystem across device renaming. `nofail` lets the host boot if the data disk is unavailable; the Ansible mount check will still stop configuration if the mount is absent.

```bash
sudo mount /srv/sftp-data
findmnt --mountpoint /srv/sftp-data
df -hT /srv/sftp-data
```

**Checkpoint:** `/srv/sftp-data` is an ext4 mount on the separate data device. The playbook checks this prerequisite; it does not format or mount the disk. I prepare it before the account and upload directory so files do not accidentally land on the OS filesystem underneath a missing mount.

### 2.4 I opened the admin node and installed the Ansible controller tools

Ansible runs tasks against a target from a **controller**. In this lab the controller is the private admin EC2, while WSL remains my Terraform workstation.

**Run in: another local WSL terminal.**

```bash
source "$HOME/.local/state/project-01b/lab.env"
aws ssm start-session --target "$ADMIN_ID"
```

**Now run in: admin SSM session.** I use the Ubuntu account consistently for the controller's files and tools:

```bash
hostname
sudo -iu ubuntu
whoami
python3 --version
command -v aws
command -v ansible-playbook
command -v session-manager-plugin
```

Missing command output is a prerequisite to fix here. For a fresh controller, I prepare a Python virtual environment so Ansible's Python packages stay separate from the OS Python:

```bash
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip curl ca-certificates
python3 -m venv "$HOME/.venvs/project-1b"
source "$HOME/.venvs/project-1b/bin/activate"
python -m pip install --upgrade pip
python -m pip install ansible-core boto3 botocore
ansible-playbook --version
```

**If AWS CLI is missing on this admin account:**

```bash
mkdir -p "$HOME/.local/tmp/project-1b-tools"
curl -fsSL https://awscli.amazonaws.com/v2/install.sh \
  -o "$HOME/.local/tmp/project-1b-tools/awscli-install.sh"
bash "$HOME/.local/tmp/project-1b-tools/awscli-install.sh"
export PATH="$HOME/.local/bin:$PATH"
```

**If the Session Manager plugin is missing:** install it on this x86_64 controller too. WSL's installation does not install anything on EC2.

```bash
curl -fL https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb \
  -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
session-manager-plugin --version
aws sts get-caller-identity --region us-east-1
```

The final command should identify the admin instance role. I do not copy my human AWS credentials or WSL profile onto this node. Its role was created by Terraform specifically for its controller duties. On a later admin login, activate the environment and PATH again:

```bash
source "$HOME/.venvs/project-1b/bin/activate"
export PATH="$HOME/.local/bin:$PATH"
```

**Checkpoint:** Ansible, Python AWS libraries, AWS CLI, and the Session Manager plugin work on the admin node. It can use its instance role.

### 2.5 I created the SFTP key and staged the files the controller would need

The transfer identity needs a dedicated key. The **private key** stays with the client; the **public key** is installed on the server. Possessing the public key alone does not let someone log in.

**Run in: local WSL, outside either SSM session.**

```bash
source "$HOME/.local/state/project-01b/lab.env"
cd ~/project-01b-proactive-linux-hardening
install -d -m 0700 ~/.ssh
umask 077
ssh-keygen -t ed25519 -f ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -C project-1b-sftpdata
```

Choose a passphrase at the prompt. If the dedicated key already exists, use it rather than overwriting it. Next I stage only the public key and the Ansible source files:

```bash
aws s3 cp ~/.ssh/mds-linux-hardening-1b-sftpdata.pub \
  "s3://$TRANSFER_BUCKET/sftpdata/sftpdata.pub"
aws s3 cp ansible/ "s3://$TRANSFER_BUCKET/project-1b/ansible/" \
  --recursive --exclude 'inventory/hosts.yml'
printf 'Controller needs bucket: %s\nTarget ID: %s\n' "$TRANSFER_BUCKET" "$TARGET_ID"
```

I use those two output values in the admin terminal next. They are identifiers, not passwords. Files in this bucket expire through its one-day lifecycle policy, so restage them if the lab resumes after expiry.

**Run in: admin SSM session, as Ubuntu with the virtual environment activated.**

```bash
read -r -p 'Paste the transfer bucket name from WSL: ' TRANSFER_BUCKET
read -r -p 'Paste the target instance ID from WSL: ' TARGET_ID
export TRANSFER_BUCKET TARGET_ID
mkdir -p ~/project-1b
aws s3 cp "s3://$TRANSFER_BUCKET/project-1b/ansible/" \
  ~/project-1b/ansible/ --recursive --region us-east-1
aws s3 cp "s3://$TRANSFER_BUCKET/sftpdata/sftpdata.pub" \
  /tmp/sftpdata.pub --region us-east-1
chmod 0644 /tmp/sftpdata.pub
cd ~/project-1b
ls ansible
test -s /tmp/sftpdata.pub && echo 'SFTP public key is ready'
```

**Checkpoint:** the controller has the playbook, inventory example, collection requirements, and public key. The private key is still only on WSL.

### 2.6 I built the inventory and tested Ansible connectivity before changing the target

An **inventory** tells Ansible which machine to manage and how to reach it. My [inventory example](../ansible/inventory/hosts.example.yml) uses `amazon.aws.aws_ssm`; it does not use an SSH private key to administer the host.

**Run in: admin SSM session, in `~/project-1b`.**

```bash
source "$HOME/.venvs/project-1b/bin/activate"
cd ~/project-1b
cp -n ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
python - <<'PY'
from pathlib import Path
import os

path = Path('ansible/inventory/hosts.yml')
text = path.read_text()
text = text.replace('i-REPLACE_WITH_TARGET_INSTANCE_ID', os.environ['TARGET_ID'])
text = text.replace('REPLACE_WITH_TRANSFER_BUCKET', os.environ['TRANSFER_BUCKET'])
path.write_text(text)
PY
cat ansible/inventory/hosts.yml
ansible-galaxy collection install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory/hosts.yml --graph
ansible sftp_target -i ansible/inventory/hosts.yml -m ansible.builtin.ping
```

The inventory should show the actual target ID, `us-east-1`, the correct bucket, the SSM connection type, and `/tmp/sftpdata.pub` as the public-key path. If you reuse an inventory from an old deployment, edit its old identifiers with `nano` rather than assuming placeholder replacement updated them. The collection list comes from [requirements.yml](../ansible/requirements.yml). Ansible's `ping` is a Python/connectivity test, not ICMP; expected output includes `pong`.

**Problem I encountered:** a working SSM shell did not guarantee Ansible could run. Its module transfer also needed the plugin, collection, controller permissions, and S3 connectivity. I checked those separately. The S3 endpoint policy in [network.tf](../terraform/network.tf) and the controller permissions in [iam.tf](../terraform/iam.tf) both matter.

**Checkpoint:** inventory is correct and Ansible returns `pong`. I can now discuss and apply the policy with confidence that the management path works.

### 2.7 I reviewed the account, filesystem, and SSH policy before applying it

The transfer user's job is to move files. It does not need `sudo`, an interactive shell, forwarding, or permission to change the host. I chose a user named `sftpdata` in group `sftp-only`, with a locked password and `/usr/sbin/nologin` shell. The [target playbook](../ansible/playbooks/harden-target.yml) declares those settings and installs the public key staged above.

I also separated the root of the restricted filesystem from the writable folder:

| Path on the target | Owner and mode | Purpose |
| --- | --- | --- |
| `/srv/sftp-data` | `root:root`, `0755` | Chroot boundary; the transfer account cannot modify it |
| `/srv/sftp-data/upload` | `sftpdata:sftp-only`, `0750` | Writable transfer directory |
| `/home/sftpdata/.ssh` | `sftpdata:sftp-only`, `0700` | Private account key directory |
| `/home/sftpdata/.ssh/authorized_keys` | `sftpdata:sftp-only`, `0600` | Public keys accepted for this account |

OpenSSH requires the chroot path to be root-owned and not writable by group or others. Giving the transfer user ownership of the chroot root would break that requirement. The writable directory goes inside it.

This is the SSH drop-in content represented in the playbook, shown here for review before running it:

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
Match Group sftp-only
    ChrootDirectory /srv/sftp-data
    ForceCommand internal-sftp -d /upload
    AllowTcpForwarding no
    PermitTunnel no
    PermitTTY no
    X11Forwarding no
Match all
```

`PermitRootLogin no` blocks root SSH login. Password and keyboard-interactive authentication are disabled, while public keys remain enabled. `Match Group sftp-only` applies the restricted policy to the transfer group; `ForceCommand internal-sftp -d /upload` forces SFTP and sets its starting directory. TTY and forwarding restrictions reduce extra capabilities. The client will see `/upload`, which maps to `/srv/sftp-data/upload` on the host.

### 2.8 I syntax-checked and applied the target configuration

I used Ansible to make these changes repeatable. Before running it, I also reviewed its OS tasks: it installs the security packages, enables AppArmor and unattended-upgrades services, configures default-deny UFW, writes audit rules and log settings, and persists kernel/network values. Those controls receive a closer inspection in Layer 3. **This playbook applies the access and OS settings together**, so the next layer checks an already-configured host rather than requiring another deployment.

**Run in: admin SSM session.**

```bash
cd ~/project-1b
source "$HOME/.venvs/project-1b/bin/activate"
less ansible/playbooks/harden-target.yml
```

Press `q` to leave the file viewer. Then validate syntax before applying:

```bash
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml --syntax-check
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml
```

The syntax check should identify the playbook without an error. The apply recap should have `failed=0` and `unreachable=0`; task counts can differ with the host's starting state and file version. My original successful recap was `ok=17 changed=3 unreachable=0 failed=0`. It is historical evidence, not an exact expected count for every rebuild.

If the first mount check fails, return to Phase 2.3. If a package task fails, check repository HTTPS access. If an SSH validation task fails, read its error before reloading SSH. I keep the working target SSM session open while changing host access.

**Checkpoint:** the playbook completed without failed or unreachable tasks. A successful recap is followed by direct verification, not treated as the only evidence.

### 2.9 I checked the account, permissions, and effective SSH configuration

**Run in: target SSM session.**

```bash
hostname
findmnt --mountpoint /srv/sftp-data
getent passwd sftpdata
id sftpdata
namei -l /srv/sftp-data/upload
stat -c '%U:%G %a %n' \
  /srv/sftp-data /srv/sftp-data/upload \
  /home/sftpdata/.ssh /home/sftpdata/.ssh/authorized_keys
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1 \
  | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|forcecommand|chrootdirectory|allowtcpforwarding|permittty)'
```

The account should have `nologin`, no sudo group, and the ownership/modes from Phase 2.7. My account had UID/GID 1002, but I use names because numeric IDs can differ on a rebuild. `sshd -t` checks syntax; no output with a successful exit is normal. `sshd -T -C` evaluates the actual `Match` policy for the SFTP user, including the chroot and forced SFTP command.

**Problem I encountered:** the first effective-config check complained that `/run/sshd` did not exist. Only for that specific missing-directory error, I created the runtime directory and retried the checks:

```bash
sudo install -d -o root -g root -m 0755 /run/sshd
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1
```

**Checkpoint:** the live account, permissions, and effective policy match the intended restriction. I save the functional upload/download and denied-action tests for Layer 4, after inspecting the OS controls.

## 3. Linux operating system hardening

An AWS network boundary controls reachability, while Linux controls what happens on the machine. With the Ansible run complete, I now inspect the OS controls in order. The manual correction blocks below explain the underlying operations and are used only if a check shows the setting is missing; a successful playbook run should already have applied its declared policy.

**All commands in this layer run in the target SSM session.** Start with `hostname` whenever returning to a terminal. I previously confused WSL and EC2 results, so this became a habit.

### 3.1 I checked packages, updates, and reboot requirements

Hardening does not remove the need to patch. First I wanted to know what was installed and whether pending maintenance would affect later tests:

```bash
hostname
dpkg-query -W -f='${Package} ${Status} ${Version}\n' \
  openssh-server ufw apparmor unattended-upgrades auditd audispd-plugins
sudo apt-get update
apt list --upgradable 2>/dev/null
```

Each required package should say `install ok installed`. A missing package must be installed before checking its service. I then reviewed available updates; when applying ordinary upgrades in this lab, I used:

```bash
sudo apt-get upgrade
```

Read the proposed package changes before accepting. My run left `cloud-init`, `tmux`, `ubuntu-pro-client`, and `ubuntu-pro-client-l10n` deferred due to phasing. I did not override Ubuntu's phased rollout just to make the list empty.

```bash
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo 'No reboot is currently required'
fi
```

**Checkpoint:** I know the package state and reboot requirement. My output said no reboot was required. If yours requests one, complete and verify that maintenance before treating later checks as final.

### 3.2 I checked AppArmor and automatic update scheduling

AppArmor adds process-specific restrictions beyond ordinary file ownership. Installing it is not enough; I need to know which profiles are loaded and enforcing.

```bash
systemctl is-enabled apparmor
systemctl is-active apparmor
sudo aa-status
```

My results were `enabled` and `active`, with 122 profiles loaded and 26 enforcing. `chronyd` and `rsyslogd` were among the enforced processes. The SSM Agent's profile was in complain mode. I read those actual states instead of assuming every process was confined because the service ran.

Next I checked the automatic-update configuration and schedule:

```bash
systemctl is-enabled unattended-upgrades
systemctl is-active unattended-upgrades
apt-config dump | grep -E 'APT::Periodic|Unattended-Upgrade::Allowed-Origins|Unattended-Upgrade::Origins-Pattern'
systemctl list-timers 'apt-daily*' --all --no-pager
sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
```

My service was enabled and active. Its log showed allowed Ubuntu Noble/security origins and no packages eligible at that particular run. An active service alone is not proof the periodic configuration will schedule updates, so I check the configuration and timers as well.

If periodic update settings are missing, create them deliberately, then verify:

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
apt-config dump | grep 'APT::Periodic'
```

This is a follow-along correction if needed, not a claim that I had to write that file during the original lab. The two `1` values enable daily package-list updates and unattended upgrades. I review allowed origins separately; the policy decides which updates qualify.

**Checkpoint:** I can describe the actual AppArmor enforcement state and see the unattended-update configuration, schedule, and available log evidence.

### 3.3 I checked the host firewall, then verified management still worked

Security groups filter traffic at the AWS boundary. UFW provides a host firewall policy on Ubuntu. I wanted default-deny incoming traffic, while allowing outbound traffic needed for updates and management. The effective outbound path still has to satisfy the AWS security group.

First I inspected the current state:

```bash
sudo ufw status verbose
sudo ufw status numbered
grep '^IPV6=' /etc/default/ufw
sudo ss -lntup
```

Before the lab changes, UFW was inactive. After Ansible, I expected `active`, default `deny (incoming)`, `allow (outgoing)`, low logging, and `IPV6=yes`. There is no inbound SSH exception because the management path is SSM.

These are the manual commands I used to establish the policy; they are also a correction sequence if the expected settings are absent:

```bash
sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw logging low
sudo ufw --force enable
sudo ufw status verbose
```

`--force` suppresses the interactive enable prompt. I had an SSM management path before doing this. An SSH-only host needs its management rule arranged first; the sequence here is specific to this SSM lab.

**Problem I encountered:** I accidentally pasted `ufw status numbered` together with `IPV6=yes`, which produced a syntax error. I reran the command on its own. Earlier, `ufw: command not found` came from WSL, not the target. I checked the host instead of installing packages on the wrong machine.

**Checkpoint:** UFW reports the intended policy. From a separate WSL terminal, load `lab.env` and open a fresh `aws ssm start-session --target "$TARGET_ID"`; run `hostname` there to confirm that new management access still works. Keep the original session open until that succeeds.

### 3.4 I verified auditd, then loaded rules before testing events

Auditd records selected security-relevant activity. I wanted evidence of changes to identity files, sudo policy, SSH configuration, and firewall configuration. First I checked that the daemon existed and ran:

```bash
dpkg-query -W -f='${Status} ${Version}\n' auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

**If it is missing**, complete installation before enabling it:

```bash
sudo apt-get update
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

This ordering mattered in my lab: I initially tried to enable `auditd.service` before the package was installed, and the unit did not exist. Once installation completed, the service reported `enabled` and `active`.

Only then did I inspect the audit subsystem and rules:

```bash
sudo auditctl -s
sudo auditctl -l
```

The original empty setup reported `No rules`. These watches are declared in the playbook. The manual equivalent below writes one persistent rules file and loads it before I try to generate any events:

```bash
sudo tee /etc/audit/rules.d/99-project-hardening.rules >/dev/null <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k privileged-access
-w /etc/sudoers.d -p wa -k privileged-access
-w /etc/ssh/sshd_config -p wa -k ssh-config
-w /etc/ssh/sshd_config.d -p wa -k ssh-config
-w /etc/ufw -p wa -k firewall
EOF
sudo augenrules --check
sudo augenrules --load
sudo auditctl -l
sudo auditctl -s
```

`-w` watches a path, `-p wa` selects writes and attribute changes, and `-k` gives the event a searchable key. The `identity` key groups account files; `privileged-access` groups sudo configuration. `augenrules --load` puts the persistent definitions into the active kernel rule set. I expected all nine watches in `auditctl -l`; later checks showed zero lost events and backlog limit 8192.

**Problem I encountered:** pasting `auditctl -s` twice onto one line produced “Too many options.” Running one clean status command fixed that input error. The separate status fields matter: `enabled 1` describes auditing state, while `lost 0` indicates no events lost at that check.

Next I inspected the log-retention settings, so the audit output would not grow without bounds:

```bash
sudo grep -E '^(flush|freq|max_log_file|num_logs|max_log_file_action|space_left|space_left_action|admin_space_left|admin_space_left_action|disk_full_action|disk_error_action)[[:space:]]*=' /etc/audit/auditd.conf
```

My policy was:

```text
flush = INCREMENTAL_ASYNC
freq = 50
max_log_file = 8
num_logs = 5
max_log_file_action = ROTATE
space_left = 75
space_left_action = SYSLOG
admin_space_left = 50
admin_space_left_action = SUSPEND
disk_full_action = SUSPEND
disk_error_action = SUSPEND
```

The 8-MiB file limit and five-log rotation keep a bounded local history. The low-space/error actions define when logging warns or suspends; they do not provide central retention. If correcting these settings manually, use `sudo nano /etc/audit/auditd.conf` to edit existing keys once, then `sudo service auditd restart` and recheck `sudo auditctl -s`. The playbook manages the same settings.

With the daemon and rules ready, I made a harmless test change:

```bash
sudo touch /etc/ufw/.audit-lab-test
sudo rm /etc/ufw/.audit-lab-test
sudo ausearch -k firewall -ts recent -i
```

I found creation and deletion records for the exact test path, with `touch` and `rm` in the process data and `key=firewall`. The earlier `CONFIG_CHANGE` event only showed that I added the rule; the later file events proved it captured activity.

For other watched configuration changes, I can use these focused queries:

```bash
sudo ausearch -k identity -ts today -i
sudo ausearch -k privileged-access -ts today -i
sudo ausearch -k ssh-config -ts today -i
sudo ls -lh /var/log/audit/
sudo augenrules --check
```

`-i` interprets numeric fields. My SSM-session events had `auid=unset`; that means these records did not identify the human IAM caller. I would correlate them with AWS session records for that attribution. The watches record operations and metadata, not full file contents or a complete SFTP transcript.

**Checkpoint:** auditd is active, all intended watches are loaded, and an actual create/delete test produced the expected events.

### 3.5 I inspected kernel settings before applying and rechecking corrections

`sysctl` exposes kernel settings. I wanted to inspect their current values first, then persist deliberate changes rather than assume the defaults were right. This server is an SFTP host, so it does not need to route packets or advertise alternate network routes.

```bash
sudo sysctl kernel.randomize_va_space kernel.dmesg_restrict kernel.kptr_restrict \
  fs.protected_hardlinks fs.protected_symlinks net.ipv4.ip_forward \
  net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects \
  net.ipv4.conf.ens5.send_redirects net.ipv4.conf.all.accept_source_route \
  net.ipv4.conf.default.accept_source_route net.ipv4.conf.ens5.accept_source_route
```

My initial inspection found `send_redirects` and `accept_source_route` still enabled in the default/interface settings. Ansible should already have corrected these on a rebuild. I checked the interface name with `ip -br link`; my target used `ens5`, which is also the interface used in the playbook.

The manual network-only correction I used was:

```bash
sudo tee /etc/sysctl.d/99-linux-hardening-network.conf >/dev/null <<'EOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.ens5.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.ens5.accept_source_route = 0
EOF
sudo sysctl -p /etc/sysctl.d/99-linux-hardening-network.conf
```

The quoted heredoc writes the lines literally; `sysctl -p` applies that file. This manual block replaces the whole named file, while the playbook writes additional host settings to the same path. On a playbook-managed rebuild, inspect its complete file and apply that instead of replacing it with this shorter historical block.

Then I checked the persistent file and live kernel values:

```bash
sudo cat /etc/sysctl.d/99-linux-hardening-network.conf
```

```bash
sudo sysctl -p /etc/sysctl.d/99-linux-hardening-network.conf
sudo sysctl \
  kernel.randomize_va_space kernel.dmesg_restrict kernel.kptr_restrict \
  fs.protected_hardlinks fs.protected_symlinks \
  net.ipv4.ip_forward \
  net.ipv4.conf.all.accept_redirects \
  net.ipv4.conf.default.accept_redirects \
  net.ipv4.conf.all.send_redirects \
  net.ipv4.conf.default.send_redirects \
  net.ipv4.conf.ens5.send_redirects \
  net.ipv4.conf.all.accept_source_route \
  net.ipv4.conf.default.accept_source_route \
  net.ipv4.conf.ens5.accept_source_route \
  net.ipv4.conf.all.rp_filter net.ipv4.conf.ens5.rp_filter \
  net.ipv4.tcp_syncookies \
  net.ipv6.conf.all.accept_redirects \
  net.ipv6.conf.all.accept_source_route
```

My corrected `all`, `default`, and `ens5` redirect/source-route settings read back as `0`. I checked all three because looking only at `all` can hide a different interface/default value. These were the recorded values and their purposes:

| Setting | Recorded value | Intended effect |
| --- | ---: | --- |
| `kernel.randomize_va_space` | `2` | Enables full address-space layout randomization for supported mappings |
| `kernel.dmesg_restrict` | `1` | Restricts access to kernel logs that can reveal sensitive system details |
| `kernel.kptr_restrict` | `1` | Reduces exposure of kernel pointer addresses through proc interfaces |
| `fs.protected_hardlinks`, `fs.protected_symlinks` | `1` | Add ownership checks against unsafe hard-link and symlink patterns in sticky directories |
| `net.ipv4.ip_forward` | `0` | Prevents this host from routing IPv4 packets between interfaces |
| IPv4 `accept_redirects` | `0` | Ignores redirects that could alter a host's routing behavior |
| IPv4 `send_redirects` | `0` | Does not advertise alternate routes to other hosts |
| IPv4 `accept_source_route` | `0` | Rejects packets whose source specifies a route through the network |
| `net.ipv4.conf.*.rp_filter` | `2` | Uses loose reverse-path validation; this is more tolerant of asymmetric routes than strict mode `1` |
| `net.ipv4.tcp_syncookies` | `1` | Enables SYN-cookie protection when the kernel's SYN backlog is under pressure |
| IPv6 redirect/source-route acceptance | `0` | Disables the corresponding IPv6 route-control behaviors |

**Checkpoint:** the saved configuration and live values agree. `rp_filter=2` is loose mode; I retained it for the routing design rather than blindly changing it to strict mode. I would review network assumptions again for a VPN or asymmetric-routing deployment.

### 3.6 I reviewed service health and logs after the changes

```bash
systemctl --failed --no-pager
sudo systemctl is-active rsyslog
sudo journalctl --disk-usage
sudo journalctl -p warning --since today --no-pager
```

My failed-unit check returned `0 loaded units listed`; rsyslog was active and the journal used 38.3 MiB. I reviewed boot-time virtual-hardware notices, a clock correction, IRQ-affinity messages, and a UFW block event in context. A logged block showed UFW had denied a packet; it did not mean SFTP accepted that packet.

The kernel also reported MDS/MMIO CPU notices. I inspected the guest status with:

```bash
cat /sys/devices/system/cpu/vulnerabilities/mds
cat /sys/devices/system/cpu/vulnerabilities/mmio_stale_data
```

The guest reported attempted buffer clearing, no microcode, and unknown SMT host state. I recorded the actual output without treating it as a complete assessment of AWS's underlying host. This inspection did not require changing SSH or firewall rules.

**Checkpoint:** I have reviewed host health, the evidence from each control, and any remaining messages. I can now test the actual file-transfer workflow.

## 4. Validation and cleanup

### 4.1 I obtained the server fingerprint before trusting the SFTP connection

The client key proves my transfer user's identity to the server. The server's **host key** lets my client verify which server it reached. I checked the host fingerprint over the existing SSM management channel first.

**Run in: target SSM session.**

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Keep that public fingerprint available for comparison. Then start the tunnel from WSL.

**Run in: local WSL terminal A.**

```bash
source "$HOME/.local/state/project-01b/lab.env"
aws ssm start-session --target "$TARGET_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}'
```

Leave terminal A open. It forwards local port 2222 to the target's local SSH service on 22. It creates no inbound security-group rule. SSM's tunnel does not provide a log of the encrypted file contents, so I rely on the test results and appropriate host evidence for the transfer behavior.

**Run in: another local WSL terminal B.**

```bash
sftp -P 2222 -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 sftpdata@127.0.0.1
```

On the first connection, compare the displayed ED25519 SHA-256 fingerprint with the one obtained through SSM before accepting it. If it differs, stop and investigate. A reused local tunnel port may have an old known-host entry; verify the new target before removing any old entry. I do not bypass host-key checking.

**Checkpoint:** the verified server accepts the dedicated key and I see an `sftp>` prompt. That prompt is the SFTP client, not a Linux shell.

### 4.2 I uploaded and downloaded the text file, then compared its hashes

**Run at: the `sftp>` prompt in WSL terminal B. Enter the text after the prompt, not the prompt itself.**

```text
sftp> !printf 'SFTP hardening lab transfer test\n' > /tmp/mds-sftp-test.txt
sftp> put /tmp/mds-sftp-test.txt /upload/mds-sftp-test.txt
sftp> get /upload/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
sftp> !sha256sum /tmp/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-test.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-downloaded.txt
```

The `!` prefix runs a command on my local WSL computer. `printf` creates the test file locally. `put` sends it into the server's `/upload`; `get` downloads it to a different local filename; `sha256sum` compares the two local copies. Both digests in my run matched.

The target-side destination was `/srv/sftp-data/upload/mds-sftp-test.txt`. Inside the chroot, that same location appeared as `/upload/mds-sftp-test.txt`. The content was a test sentence, not a customer-register CSV. The successful transfer proved this file could make the round trip intact.

### 4.3 I tested actions the transfer account should be denied

A successful upload proves usability. It does not prove the user is restricted, so I also tested the boundaries.

**Still at the SFTP prompt:**

```text
sftp> pwd
sftp> cd ..
sftp> pwd
sftp> cd ..
sftp> pwd
sftp> cd /etc
sftp> put /tmp/mds-sftp-test.txt /mds-write-denied-test.txt
sftp> bye
```

From `/upload`, the first `cd ..` reaches the chroot's `/`; the next cannot escape that root. The host's real `/etc` is outside this view, and writing to the chroot root should return `Permission denied`. I kept the upload directory writable and the chroot root protected.

**Back in the WSL shell in terminal B, while terminal A still holds the tunnel:**

```bash
ssh -T -p 2222 -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes sftpdata@127.0.0.1 id
```

My response was `This service allows sftp connections only.` That was the intended denied-shell result, not an SSH service failure. The account could transfer a file but could not run `id` as a shell command.

I also compared the saved host-key fingerprint with the one I obtained through SSM:

```bash
ssh-keygen -F '[127.0.0.1]:2222' | ssh-keygen -lf - -E sha256
```

**Checkpoint:** transfer succeeds within `/upload`, escape/root-write attempts fail, shell execution is denied, and the server identity matches. After testing, stop the tunnel with `Ctrl+C` in terminal A.

### 4.4 I recorded what the evidence established

| Check | My recorded result |
| --- | --- |
| Management path | Both private EC2 nodes were managed with SSM; no public IP or inbound security-group rule |
| Account boundary | Dedicated key, SFTP-only identity, root-owned chroot and restricted writable child directory |
| Transfer | `mds-sftp-test.txt` uploaded and downloaded; SHA-256 values matched |
| Denied actions | Chroot-root write and shell command were refused |
| Host firewall | UFW active, default deny incoming, allow outgoing; new SSM and tunneled SFTP access still worked |
| Host monitoring | auditd active, nine watches loaded, harmless test events captured, zero lost events at status check |
| Maintenance and host settings | AppArmor/service state, update results, persistent sysctls, logs, and failed units inspected |

I kept the [verification record](verification.md) and [hardening evidence](../evidence/hardening-results.md) alongside the code. My journal retained the mistakes too: the wrong WSL PATH, missing CLI profile, host confusion, Ansible's extra S3 dependency, an auditd unit checked before installation, and pasted commands accidentally joined together. Each taught me to check a prerequisite or the actual source of an output before changing policy.

### 4.5 I removed the temporary files and destroyed the AWS infrastructure

Finishing the demonstration included removing the running resources. I closed my SFTP/tunnel sessions and exited the EC2 shells. **Run the remaining commands in local WSL**, using the same repository and Terraform state that created this lab.

```bash
source "$HOME/.local/state/project-01b/lab.env"
cd ~/project-01b-proactive-linux-hardening
aws sts get-caller-identity
terraform -chdir=terraform state list
printf 'Lab bucket selected for cleanup: %s\n' "$TRANSFER_BUCKET"
aws s3 ls "s3://$TRANSFER_BUCKET/" --recursive
```

I check the selected account and bucket before deleting anything. In my first destroy attempt, the S3 bucket still contained the public-key object, so AWS returned `BucketNotEmpty`. For a repeat run, I clear the verified lab bucket before destroying it:

```bash
aws s3 rm "s3://$TRANSFER_BUCKET/" --recursive
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
terraform -chdir=terraform state list
```

I review the destroy plan, then enter `yes` only when it names the intended lab resources. If a partial destroy already deleted the bucket, an S3 `NoSuchBucket` response means that cleanup step is no longer needed; continue with Terraform's remaining resources. A connection error is different and needs investigation.

After removing the bucket contents, my final run reported `Destroy complete! Resources: 1 destroyed.` That was the last resource from the earlier partial teardown. `terraform state list` was empty afterward. I retained the local state and evidence until I finished checking the result.

### 4.6 I checked AWS service state after Terraform finished

An empty Terraform state shows what that state file still manages; I also checked AWS. These queries use the saved IDs and project tag, so there is no need to look up old outputs after destroy:

```bash
aws ec2 describe-instances --instance-ids "$ADMIN_ID" "$TARGET_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' --output table
aws ec2 describe-nat-gateways \
  --filter Name=tag:Project,Values=mds-linux-hardening-1b \
  --query 'NatGateways[].{ID:NatGatewayId,State:State}' --output table
aws ec2 describe-volumes \
  --filters Name=tag:Project,Values=mds-linux-hardening-1b \
  --query 'Volumes[].{ID:VolumeId,State:State}' --output table
aws ec2 describe-vpc-endpoints \
  --filters Name=tag:Project,Values=mds-linux-hardening-1b \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,State:State}' --output table
aws ec2 describe-addresses \
  --filters Name=tag:Project,Values=mds-linux-hardening-1b \
  --query 'Addresses[].{Allocation:AllocationId,Address:PublicIp}' --output table
aws s3api list-buckets \
  --query "Buckets[?Name=='$TRANSFER_BUCKET'].Name" --output text
```

My checks showed both instances `terminated`, the NAT Gateway `deleted`, the queried endpoint absent, and no volumes in the filtered volume result. Deleted instances can remain visible briefly; later their IDs can return not found. The tagging API still listed old ARNs, which did not override the direct service states. My S3 listing could not reach its endpoint at that time, so I recorded the Terraform deletion separately from that unavailable check.

**Final checkpoint:** Terraform state is empty, direct service checks show no active lab resources in the queried scope, and any query error is recorded rather than interpreted as success. My demonstration ended with the infrastructure torn down and the documentation available to repeat the work.

