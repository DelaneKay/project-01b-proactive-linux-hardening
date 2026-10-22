# My Project 1B proactive Linux hardening journey

- **Core technologies:** AWS, AWS CLI, Terraform, IAM, Systems Manager Session Manager, Ubuntu, Ansible, OpenSSH/SFTP, AppArmor, UFW, and auditd.
- **Problem addressed:** I needed to build a private file-transfer server, restrict the transfer account to its intended job, and harden the Linux host without opening public SSH access.
- **Outcome:** I provisioned the AWS lab with Terraform, managed the private target through Session Manager, and used Ansible and Linux controls to configure it. The SFTP account could transfer a test text file but could not write at the chroot root or start a shell. Matching SHA-256 hashes confirmed the file survived upload and download intact. After the demonstration, I used `terraform destroy` to remove the lab resources.

This is my account of Project 1B: building and hardening a private SFTP server on AWS, then checking that the access restrictions worked. I used the small `mds-sftp-test.txt` fixture containing `SFTP hardening lab transfer test`. The walkthrough follows the work from local preparation through AWS access, infrastructure, server hardening, validation, and teardown.

## The lab scenario

I wanted a file-transfer service that could accept a file from an authorized user while keeping the server private and limiting that user's access to the upload area. I built a new AWS lab environment rather than investigating a pre-existing compromised server.

I kept several security principles in mind as I worked. Infrastructure as Code made the cloud design reviewable and repeatable. Private subnets and Session Manager reduced the need to expose SSH to the internet. Least privilege shaped the SFTP account and its chroot boundary. Audit rules and host logs helped me observe security-relevant activity, while SHA-256 checksums let me verify the transferred file's integrity.

I worked from Ubuntu in WSL with Terraform and the AWS CLI, using IAM and browser-based AWS sign-in to manage the account. Terraform created two private EC2 instances: an admin node that ran Ansible and a target node that hosted the SFTP service. I connected to the admin node with Session Manager; Ansible then used `amazon.aws.aws_ssm` and a private S3 transfer bucket to configure the target. On that target, I checked Linux services and applied AppArmor, UFW, auditd, and kernel hardening. After testing SFTP and comparing file hashes, I used Terraform to tear down the lab.

### The three-node lab layout

The lab had three working nodes: my WSL workstation, the private admin EC2 instance, and the private target EC2 instance. The arrows show the management and configuration flow:

```text
WSL workstation
(Terraform + AWS CLI)
        |
        | Session Manager
        v
Private admin EC2
(Ansible controller)
        |
        | amazon.aws.aws_ssm
        | temporary module transfer through private S3 bucket
        v
Private target EC2
(Ubuntu 24.04, SFTP-only workload)
        |
        +-- encrypted 20 GiB root EBS volume
        +-- encrypted 5 GiB SFTP data volume
            mounted at /srv/sftp-data

Both EC2 nodes:
  - no public IP
  - no inbound security-group rules
  - IMDSv2 required

Private subnet egress: NAT Gateway
S3 transfer traffic: S3 Gateway endpoint
```

The admin and target instances had no public IPs or inbound security-group rules. Session Manager let me administer them through AWS-managed sessions, while the S3 Gateway endpoint carried the temporary files Ansible needed without routing that S3 traffic through the NAT Gateway. This walkthrough follows the dependencies from the beginning: I explain each tool before using it, identify the terminal for each command, and give a checkpoint before the next phase. Repository file links show the configuration alongside the walkthrough.

| Layer | Sequence |
| --- | --- |
| 1. AWS infrastructure | Understand automation → prepare WSL → check/install tools → authenticate to AWS → get the project files → inspect AWS → define infrastructure → plan and deploy |
| 2. Access management and SSH hardening | Confirm SSM connectivity → inspect the target → prepare its disk → prepare the Ansible controller → stage the public key and configuration → review the access policy → apply and check it |
| 3. Linux operating system hardening | Check packages and updates → inspect AppArmor → verify the host firewall → load and test audit rules → verify kernel settings → review host health |
| 4. Validation and cleanup | Verify the server identity → transfer the text file → test denied actions → retain evidence → destroy resources → check the result |

**Starting point:** I began on my Windows workstation with Ubuntu in WSL and authorized access to an AWS account for this lab. Each step names the terminal to use. I treated the shell and SFTP prompts as indicators of which terminal I was in, not as text to copy into a command. I worked through one block at a time and fixed errors before moving on.

## 1. AWS infrastructure layer

### 1.1 Why I started with automation, then checked my local WSL environment

Automation is central to DevSecOps because I need changes I can review, repeat, and remove reliably. I chose **Infrastructure as Code (IaC)** for the AWS resources: describe the desired infrastructure in files, review a proposed change, and let Terraform create it consistently. Later, Ansible would configure the Linux server. Terraform and Ansible have different jobs, so I prepared Terraform first.

Before touching AWS, I needed to know which Linux environment and user I was working in.

I ran these checks in the Ubuntu terminal on my WSL workstation:

```bash
whoami
hostname
cat /etc/os-release
uname -r
```

`whoami` identifies my local Linux user, `hostname` identifies the machine, and the last two commands identify the operating system and kernel. My workstation reported a Microsoft WSL2 kernel. This was my local computer; no EC2 instance existed yet.

I initially worked as root, so I created a regular account for routine commands and added it to the `sudo` group for tasks that needed elevation. I ran this setup because I was root and `devsecops` did not exist; if your WSL account already has `sudo` access, continue with that account.

```bash
adduser devsecops
usermod -aG sudo devsecops
id devsecops
su - devsecops
```

`adduser` creates the local account and asks for its password. `usermod -aG sudo` adds it to the sudo group while preserving other groups. `id devsecops` confirms the account and memberships; `su -` switches to that user's login environment. 

Before installing or using the AWS tools, I checked that I had switched out of root and could still elevate when a system-level change required it. Running routine work as an ordinary user limits unnecessary root access; `sudo` remains available for tasks that need it.

```bash
whoami
sudo whoami
```

**Checkpoint:** `whoami` should show my ordinary WSL account, while `sudo whoami` should return `root`. That confirmed the local Linux privileges were set up as intended. This account is separate from the AWS identity I configure next.

### 1.2 I checked Terraform and AWS CLI before trying to use them

I checked these versions from my ordinary WSL account:

```bash
terraform version
aws --version
```

Terraform manages the infrastructure files; the AWS Command Line Interface (CLI) lets me authenticate and query AWS. These version checks showed which tools were available to my current user.

My Terraform check returned version `1.16.6`. AWS CLI was available under a different user but initially returned `command not found` for `devsecops`. I learned that installing a tool under root does not make a user-local installation available to every account.

Terraform was already installed, so I did not install it again. The version check confirmed that the expected Terraform tool was available.

For the missing AWS CLI, I ran AWS's v2 installer from my ordinary `devsecops` WSL account. This command downloads the installer and passes it to Bash; the Linux default installs for the current user, placing the executable under `/home/devsecops/.local/bin` ([AWS CLI installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)):

```bash
curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash
```

The installation reported AWS CLI `2.38.3`. I checked the user-local executable directly:

```bash
/home/devsecops/.local/bin/aws --version
```

I added the AWS CLI location to `PATH` for this shell and saved it in `~/.bashrc` for future shells. I then checked AWS CLI and Terraform again and checked whether Ansible was installed locally:

```bash
export PATH="$HOME/.local/bin:$PATH"
source ~/.bashrc
aws --version
terraform version
ansible --version
```

The check showed that Ansible was not installed in WSL. I used WSL for Terraform and the AWS CLI, and ran Ansible from the private admin EC2 instance, which served as the controller for the target.

**Checkpoint:** Terraform and AWS CLI were ready in WSL. I had not signed in to AWS or created any resources yet, so my next step was to establish an authorized AWS identity.

### 1.3 I established an AWS identity before using a named profile

Having `aws` installed does not grant access to an AWS account. My first identity check returned `NoCredentials`, so I needed to authenticate the CLI before AWS could identify me or accept account changes.

For this lab, I used a dedicated IAM user and a named AWS CLI profile. A profile is the local configuration that selects credentials and settings; the Linux user `devsecops`, IAM user `mds-devsecops-lab`, and CLI profile `mds-devsecops-lab` are separate identities.

For the initial AWS account setup, I used the AWS account root user to create a separate lab IAM user and enroll MFA. I then signed in as that IAM user with browser-based `aws login`, which supplied short-lived CLI credentials. For this lab, that was a better fit than using the legacy `aws configure` prompts to save long-lived IAM access keys. It improved security by avoiding a reusable access key in my local AWS configuration; the temporary CLI credentials expired, limiting how long they could be used if exposed. If I already had an authorized IAM Identity Center role, I could use it for the lab instead of creating a separate IAM user.

I ran the identity check before signing in, then started browser sign-in and set the default Region:

```bash
aws sts get-caller-identity
aws login
aws configure set region us-east-1
```

`aws login` opened browser sign-in; the Region setting selected where later requests would go, not the credentials. Once authenticated, I confirmed the active identity was root before creating the separate lab user.

With the root identity confirmed, I created the separate lab IAM user, granted it browser-based CLI sign-in and the permissions needed to provision this lab, then checked the attached policies. I ran these bootstrap commands before the named lab profile existed:

```bash
aws iam create-user --user-name mds-devsecops-lab --query 'User.UserName' --output text
aws iam attach-user-policy --user-name mds-devsecops-lab --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam attach-user-policy --user-name mds-devsecops-lab --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
aws iam list-attached-user-policies --user-name mds-devsecops-lab
```

`SignInLocalDevelopmentAccess` enabled browser-based CLI sign-in. `AdministratorAccess` supplied the human lab user's broad resource permissions; neither server received that administrator policy.

With the policies attached, I created an AWS console login profile for the IAM user `mds-devsecops-lab`. The password I entered here was that user's initial AWS Management Console password, which AWS required them to change at first sign-in. The script hid the password and confirmation, passed them to AWS in a restricted temporary file, and removed the file when it exited:

```bash
set -e
umask 077
login_input="$(mktemp)"
trap 'rm -f "$login_input"' EXIT

python3 - "$login_input" <<'PY'
import getpass
import json
import sys

password = getpass.getpass("Choose a temporary password for mds-devsecops-lab: ")
confirmation = getpass.getpass("Enter it again: ")

if password != confirmation:
    raise SystemExit("Passwords did not match; no login profile was created.")

with open(sys.argv[1], "w") as file:
    json.dump({
        "UserName": "mds-devsecops-lab",
        "Password": password,
        "PasswordResetRequired": True
    }, file)
PY

aws iam create-login-profile \
  --cli-input-json "file://$login_input" \
  --query 'LoginProfile.UserName' \
  --output text
```

I created a virtual MFA device and scanned its private QR image. My first attempt to open the image from WSL failed with `explorer.exe: command not found`:

```bash
explorer.exe "$(wslpath -w "$HOME/.aws/mds-devsecops-lab-mfa.png")"
```

I used `wslpath` to convert the Linux image location into a Windows path that File Explorer could open:

```bash
wslpath -w /home/devsecops/.aws/mds-devsecops-lab-mfa.png
```

After switching back to `devsecops`, I loaded the virtual MFA device's serial into the current shell so the enrollment request could refer to the correct authenticator:

```bash
export mfa_serial="$(aws iam list-virtual-mfa-devices \
  --query "VirtualMFADevices[?contains(SerialNumber, 'mds-devsecops-lab')].SerialNumber | [0]" \
  --output text)" && printf 'MFA device serial loaded for enrollment.\n'
```

I entered two consecutive authenticator codes through hidden prompts. The script placed the enrollment request in a private temporary file, asked IAM to attach the authenticator, and removed the file afterward:

```bash
python3 - <<'PY'
import getpass
import json
import os
import subprocess
import tempfile

serial = os.environ.get("mfa_serial")
if not serial:
    raise SystemExit("mfa_serial is not available. Reload it first in this terminal.")

code1 = getpass.getpass("First authenticator code (hidden): ")
code2 = getpass.getpass("Next code after it changes (hidden): ")

payload = {
    "UserName": "mds-devsecops-lab",
    "SerialNumber": serial,
    "AuthenticationCode1": code1,
    "AuthenticationCode2": code2,
}

fd, path = tempfile.mkstemp(prefix="mfa-enroll-", suffix=".json")
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f)
    result = subprocess.run(
        ["aws", "iam", "enable-mfa-device", "--cli-input-json", f"file://{path}"],
        check=False,
    )
    raise SystemExit(result.returncode)
finally:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
PY
```

After enrolling the device, I checked how many MFA devices IAM listed for the new user:

```bash
aws iam list-mfa-devices \
  --user-name mds-devsecops-lab \
  --query 'length(MFADevices)' \
  --output text
```

IAM returned `1`, confirming that the new user had one MFA device. I deleted the QR image after enrollment because it contains the seed used to generate MFA codes. I kept that seed, passwords, and one-time codes out of the repository, following [AWS's guidance to protect the QR seed like a password](https://docs.aws.amazon.com/IAM/latest/APIReference/API_CreateVirtualMFADevice.html). With MFA enrollment confirmed, I checked the bootstrap identity and signed out:

```bash
aws sts get-caller-identity --query 'Arn' --output text
aws logout
```

The ARN identified the root session, and `aws logout` removed its cached CLI credentials.

**Problem I encountered:** I could sign in to the IAM user's console before the named AWS CLI profile existed, but my first profile-specific CLI call returned “The config profile could not be found.” I created and authenticated the profile, then checked the active identity and default Region:

```bash
aws login --profile mds-devsecops-lab
aws sts get-caller-identity --profile mds-devsecops-lab
aws configure get region --profile mds-devsecops-lab
```

I selected the lab IAM user in the browser. `get-caller-identity` confirmed the active principal, and the Region check returned `us-east-1`. That completed the named CLI profile setup.

Later, I needed to reset the AWS console password for `mds-devsecops-lab`. Signing in again with `aws login` would refresh the CLI session, not change the console password. I used the `root-recovery` profile because it had the administrator access needed to update the IAM user's password. The block below performs that reset: it prompts for a new password and confirmation without displaying them, sends the request to IAM through a restricted temporary file, and removes the file when it exits.

```bash
(
  set -e
  umask 077

  login_input="$(mktemp)"
  trap 'rm -f "$login_input"' EXIT

  python3 - "$login_input" <<'PY'
import getpass
import json
import sys

password = getpass.getpass("New password for mds-devsecops-lab: ")
confirmation = getpass.getpass("Enter it again: ")

if not password or password != confirmation:
    raise SystemExit("Passwords are empty or do not match. Nothing changed.")

with open(sys.argv[1], "w") as file:
    json.dump({
        "UserName": "mds-devsecops-lab",
        "Password": password,
        "PasswordResetRequired": False
    }, file)
PY

  aws iam update-login-profile \
    --cli-input-json "file://$login_input" \
    --profile root-recovery \
    --no-cli-auto-prompt

  printf 'IAM user password updated successfully.\n'
)
```

The password update succeeded. I then returned to browser sign-in with the named `mds-devsecops-lab` profile and used `us-east-1` for subsequent AWS checks.

With the lab profile working, I checked whether AWS activity would be traceable before I created infrastructure. That matters because an audit record can help identify who made a change, when it happened, and what AWS resource was affected—useful when validating a lab deployment or investigating an unexpected change. I used `aws cloudtrail describe-trails` to see whether the account had a configured trail for ongoing log delivery, then `aws cloudtrail lookup-events` to check the recent management event history. The first check returned no trails, but the second still showed recent events for my lab user. I had visibility into recent activity, but no configured trail from this check; setting up broader monitoring was outside the Linux-hardening work.

### 1.4 I created the Terraform files in my local project directory

I created a working directory for the lab at `/home/devsecops/mds-aws-linux-hardening-1b` and used it to build and check the Terraform configuration before deploying anything. I confirmed I was in the right place with `cd` and `pwd`. The files were first created on my WSL machine; after the lab was complete, I organized and published them in this GitHub repository.

```bash
cd ~/mds-aws-linux-hardening-1b
pwd
```

With the workspace ready, I started by defining Terraform’s requirements and the inputs for the lab. [versions.tf](../terraform/versions.tf) records the Terraform and AWS provider versions, while [variables.tf](../terraform/variables.tf) defines the values the configuration can accept; my local `terraform.tfvars` supplied the lab-specific values. I initialized the AWS provider and validated the configuration as I built it. The commands below reflect the original layout, where the `.tf` files were directly in the working directory; they are now grouped under `terraform/` in this repository.

### 1.5 I inspected AWS before choosing the lab's network, image, and storage

I had working tools, credentials, and source files. Next I needed facts to inform the design: an unused network range, a supported Availability Zone and instance size, the intended Ubuntu image, and the account's storage-encryption default.

From WSL, I used my lab profile for read-only AWS queries. I first checked existing VPCs, Availability Zones, and T2/T3 offerings to select the network and instance sizes, then checked the Ubuntu image and EBS encryption defaults:

```bash
aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' \
  --output text \
  --profile mds-devsecops-lab \
  --region us-east-1
```

```bash
aws ec2 describe-images \
  --image-ids ami-02a9cdd4e98bc3c78 \
  --query 'Images[].{ImageId:ImageId,Name:Name,OwnerId:OwnerId,Architecture:Architecture,CreationDate:CreationDate,State:State,RootDeviceType:RootDeviceType,VirtualizationType:VirtualizationType}' \
  --output table \
  --profile mds-devsecops-lab \
  --region us-east-1
```

```bash
aws ec2 get-ebs-encryption-by-default \
  --profile mds-devsecops-lab \
  --region us-east-1
```

```bash
aws ec2 get-ebs-default-kms-key-id \
  --profile mds-devsecops-lab \
  --region us-east-1
```

The VPC query showed that my existing default VPC used `172.31.0.0/16`. I was creating a separate VPC for this lab, so `10.20.0.0/16` is the address range I assigned to the new lab VPC; it is not an address range that the existing default VPC already used. I divided that dedicated range into the NAT, admin, and target subnets in the Terraform network configuration. My checks confirmed that `us-east-1a` was available and that both `t3.small` and `t3.micro` were offered in the Region. I also verified that the Ubuntu image was available, used the `x86_64` architecture, and was published by Canonical (`099720109477`). Because Ubuntu’s image ID can change as new images are released, [ami.tf](../terraform/ami.tf) retrieves the current ID from AWS Systems Manager Parameter Store during deployment.

I checked the account’s EBS encryption defaults before setting up storage. Default encryption was disabled, although `alias/aws/ebs` was available as the default key. To make sure the lab’s root and SFTP data volumes were encrypted, I enabled encryption explicitly in [compute.tf](../terraform/compute.tf). This protects data stored on the EBS volumes; Linux permissions control access to files after the volumes are mounted.

**Problem I encountered:** my first VPC query failed with `OptInRequired`, so I stopped and retried instead of choosing a range without checking the existing network. The retry returned the default VPC details, although I never established what caused the first error.

**Checkpoint:** I had now checked the existing VPC range, assigned a separate CIDR to the lab VPC, and confirmed that the selected Availability Zone, instance sizes, and Ubuntu image were available. When repeating the lab, check these values in your own account and adjust the inputs in Phase 1.7 if needed.

### 1.6 I translated those checks into the AWS design and Terraform files

Only now did I have enough information to settle the deployment. I needed three machines with clear responsibilities: my existing WSL workstation would run Terraform and AWS CLI; a private admin EC2 would run Ansible; a private target EC2 would host SFTP.

That three-node design also shaped how I would administer the two EC2 instances. Because they would sit in private subnets without public IPs, I needed a secure way to manage them without exposing SSH to network connections. I chose Systems Manager Session Manager: IAM controls who can start a session, and each instance’s SSM agent opens an outbound connection to the service. This kept port 22 unreachable from outside the VPC, reducing exposure to scanning and SSH attacks. Since access went through IAM and Systems Manager, I did not need SSH ingress rules or a public bastion to maintain. The target still needed OpenSSH for SFTP, so I planned to use an SSM port-forwarding tunnel to reach that service without making it publicly accessible.

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

Before writing the smaller instance policy, I inspected AWS's managed `AmazonSSMManagedInstanceCore` policy. First I looked up its metadata, then read its active `v2` document and a compact summary of its actions:

```bash
aws iam get-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --query 'Policy.{Name:PolicyName,Arn:Arn,DefaultVersion:DefaultVersionId,Updated:UpdateDate}' \
  --output table \
  --profile mds-devsecops-lab
```

```bash
aws iam get-policy-version \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --version-id v2 \
  --query 'PolicyVersion.Document' \
  --output json \
  --profile mds-devsecops-lab
```

```bash
aws iam get-policy-version \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --version-id v2 \
  --query 'PolicyVersion.Document.Statement[].{Actions:Action,Resources:Resource}' \
  --output json \
  --profile mds-devsecops-lab
```

The compact query exposed parameter-read, patching, inventory, compliance, and legacy messaging permissions beyond the Session Manager channels I needed. That review led to the narrower five-action agent policy below.

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

I chose one managed NAT Gateway because it saved me operating another Linux server. The single-AZ design was appropriate for this temporary exercise. My estimate was about `$32.85/month` for continuous NAT usage and `$22.85/month` for the two instances before other charges. Those were planning estimates, not current quotes. My budget alert was a notification, so teardown was part of the plan from the beginning.

**Checkpoint:** I can explain the purpose of each resource and its permission boundary before creating it.

**Workstation troubleshooting:** my WSL terminal became unresponsive during the IAM-policy review. I was advised to try `Ctrl+C`, then use this PowerShell command if the terminal remained unresponsive:

```powershell
wsl --shutdown
```

This was recovery guidance for the local workstation, not an AWS change.

### 1.7 I initialized and validated the Terraform configuration

Before initializing and validating the Terraform configuration, I set the Region to `us-east-1`, selected profile `mds-devsecops-lab`, and reviewed the project variables in [variables.tf](../terraform/variables.tf) and [terraform.tfvars.example](../terraform/terraform.tfvars.example). I ran the checks from `~/mds-aws-linux-hardening-1b` in WSL:

```bash
terraform init
terraform validate
```

Terraform downloaded the signed AWS provider `6.69.1` and reported `Success! The configuration is valid.` I then reviewed the planned design—private instances, no inbound security-group rules, encrypted volumes, and scoped instance permissions—because syntax validation alone does not assess those choices.

### 1.8 I deployed the infrastructure and used its identifiers

I deployed the lab with Terraform from the original WSL project directory. The two private instances and transfer bucket then became the inputs for SSM, Ansible, and SFTP. [outputs.tf](../terraform/outputs.tf) exposes the instance and bucket identifiers.

The target instance ID was `i-0cce45e09ec35a12a`, and I used the `mds-devsecops-lab` profile in `us-east-1`. The historical identifiers below belong to the lab that was later destroyed.

**Checkpoint:** the AWS resources existed before I began the access configuration.

## 2. Access management and SSH hardening

### 2.1 I checked Session Manager prerequisites before opening a session

AWS resources existing does not mean I can manage them yet. Session Manager needs an agent on the instance, suitable IAM permissions and outbound connectivity, and a client plugin on my workstation.

Both nodes needed a working SSM Agent, instance permissions, and outbound connectivity. I used SSM to reach the private instances without opening public SSH access.

**Checkpoint:** I could open an SSM session to the target without public SSH access.

### 2.2 I opened a target session and captured its starting state

I kept separate terminals for WSL, the target, and later the admin controller. A command that checks the wrong host can give a perfectly valid but irrelevant answer.

From a new WSL terminal, I opened an interactive Session Manager connection to the private target using its instance ID and lab profile:

```bash
aws ssm start-session --target i-0cce45e09ec35a12a \
  --profile mds-devsecops-lab --region us-east-1
```

The prompt now belongs to the target EC2.

The SSM session opens an IAM-authorized shell on the private target. After confirming the prompt belonged to EC2, I checked its hostname, account, OS, kernel, listening ports, and running services:

```bash
hostname
whoami
cat /etc/os-release
uname -r
sudo ss -lntup
systemctl list-units --type=service --state=running --no-pager
```

My target reported Ubuntu 24.04.5 and an AWS kernel. The checks confirmed I was on the EC2 host and showed its listening services. I had previously mistaken WSL output for target output, so I used the hostname and kernel to verify the machine before interpreting later checks.

SSH listened on local port 22, alongside resolver and time-service sockets. That inventory showed which programs listened before I changed the account or SSH policy; reachability also depends on AWS network controls.

**Checkpoint:** I identified the target before interpreting its service and firewall output.

### 2.3 I prepared the dedicated data filesystem before configuring the chroot

The 5-GiB disk created by Terraform is a block device. SFTP needs a mounted filesystem. I chose `/srv/sftp-data` as the server-side storage location and future chroot root. A **chroot** gives the SFTP account a restricted filesystem view; its `/` will represent this directory.

I selected a separate data volume for the target:

The data mount used `/srv/sftp-data` on the separate disk. Its root-owned chroot and writable upload directory are described below.

**Checkpoint:** the separate data mount was in place before the SFTP account used its upload directory.

### 2.4 I opened the admin node and installed the Ansible controller tools

Ansible runs tasks against a target from a **controller**. In this lab the controller is the private admin EC2, while WSL remains my Terraform workstation.

I used the private admin node as the Ansible controller, with its instance role providing AWS permissions. The [collection requirements](../ansible/requirements.yml) document the repository's dependencies.

### 2.5 I created the SFTP key and staged the files the controller would need

The transfer identity needs a dedicated key. The **private key** stays with the client; the **public key** is installed on the server. Possessing the public key alone does not let someone log in.

My client used the dedicated key file `~/.ssh/mds-linux-hardening-1b-sftpdata`. The bucket held its public key at `sftpdata/sftpdata.pub`; the private key stayed on the workstation.

### 2.6 I configured Ansible to reach the private target

The controller used `amazon.aws.aws_ssm` with the target instance ID, Region, and transfer bucket. The published [inventory example](../ansible/inventory/hosts.example.yml) and [collection requirements](../ansible/requirements.yml) document those settings. SSM shell access and Ansible module transfer have different dependencies: Ansible also needed S3 connectivity and the controller's scoped permissions.

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

### 2.8 I applied the access configuration with Ansible

I used Ansible for the access configuration. The repository's [target playbook](../ansible/playbooks/harden-target.yml) expresses the target configuration; 

In particular, I installed auditd, enabled UFW, and corrected network sysctls manually during the subsequent checks. I describe those actions in Layer 3 rather than claim that the earlier Ansible run had already done them.

### 2.9 I verified the access restrictions through SFTP

I checked the restrictions with the transfer and denied-action tests documented in Layer 4. The captured evidence includes a refused write at the chroot root and the response `This service allows sftp connections only.

` when I tried to execute a shell command. Those results provide direct evidence of the access boundary.

## 3. Linux operating system hardening

An AWS network boundary controls reachability, while Linux controls what happens on the machine. I inspected the OS controls and applied the missing settings in the target SSM session. The commands and outputs below follow those checks and manual corrections.

I ran every command in this layer inside the target's SSM session. Whenever I returned to a terminal, I started with `hostname` to confirm which machine I was using; earlier, I had mistaken WSL output for EC2 output.

### 3.1 I checked packages, updates, and reboot requirements

Hardening does not remove the need to patch. First I wanted to know what was installed and whether pending maintenance would affect later tests: `hostname` confirms I am on the target; `apt list --upgradable` shows available package updates so I can see what maintenance is pending. 

```bash
hostname
apt list --upgradable 2>/dev/null
```

I reviewed the available updates and attempted an upgrade. 

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

AppArmor adds process-specific restrictions beyond ordinary file ownership.

I checked both whether AppArmor starts at boot and whether it was running, then inspected its loaded and enforcing profiles. A running service alone does not show which processes are actually confined.

```bash
systemctl is-enabled apparmor
systemctl is-active apparmor
sudo aa-status
```

I also checked the installed package versions, including whether the utilities needed for `aa-status` were present:

```bash
dpkg-query -W -f='${Status} ${Version}\n' apparmor apparmor-utils
```

AppArmor was installed; `apparmor-utils` was not installed.

My results were `enabled` and `active`, with 122 profiles loaded and 26 enforcing. `chronyd` and `rsyslogd` were among the enforced processes. The SSM Agent's profile was in complain mode. I read those actual states instead of assuming every process was confined because the service ran.

The service checks show whether unattended upgrades start at boot and are running now; the log shows their recent activity and allowed package origins. I checked these together:

```bash
systemctl is-enabled unattended-upgrades
systemctl is-active unattended-upgrades
sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
```

My service was enabled and active. Its log showed allowed Ubuntu Noble/security origins and no packages eligible at that particular run. I also reviewed the pasted allowed-origins configuration; the log is evidence of the run at that time.

This check looks for an automatic-reboot setting in APT's effective configuration:

```bash
sudo apt-config dump | grep -i 'Unattended-Upgrade::Automatic-Reboot'
```

That query returned no matching setting. The separate reboot-required check reported that no reboot was currently required.

The unattended-upgrades log confirmed a run, and I left the existing configuration in place.

**Checkpoint:** I confirmed the actual AppArmor enforcement state, unattended-update configuration, and recent log activity.

### 3.3 I checked the host firewall, then verified management still worked

Security groups filter traffic at the AWS boundary. UFW provides a host firewall policy on Ubuntu. I wanted default-deny incoming traffic, while allowing outbound traffic needed for updates and management. The effective outbound path still has to satisfy the AWS security group.

First I inspected the current state: `ufw status` shows the host firewall policy, and `ss` lists local listening services. I checked these before enabling the firewall so I knew the existing policy and services. 

```bash
sudo ufw status verbose
sudo ufw status numbered
sudo ss -lntup
```

Before enabling UFW, I inspected the current IPv4 and IPv6 packet-filter policies. Both checks initially showed whether input, forwarding, and output were accepted:

```bash
sudo iptables -S
sudo ip6tables -S
```

Both outputs showed `ACCEPT` policies for INPUT, FORWARD, and OUTPUT.

Before the lab changes, UFW was inactive. After enabling it manually, I verified `active`, default `deny (incoming)`, `allow (outgoing)`, low logging, and `IPV6=yes`. There is no inbound SSH exception because the management path is SSM.

I set UFW to deny incoming connections and allow outbound traffic, then enabled it and checked the resulting policy. I already had SSM access before enabling the firewall; an SSH-managed host needs its management rule arranged first.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

**Problem I encountered:** I accidentally pasted `ufw status numbered` together with `IPV6=yes`, which produced a syntax error. I reran the command on its own. Earlier, `ufw: command not found` came from WSL, not the target. I checked the host instead of installing packages on the wrong machine.

**Checkpoint:** UFW reported the intended policy. I opened a fresh target SSM session and ran `hostname`; it returned `ip-10-20-20-177`, confirming management access still worked.

### 3.4 I verified auditd, then loaded rules before testing events

Auditd records selected security-relevant activity.

`dpkg-query` checks whether auditd is installed; the two `systemctl` checks show whether it starts at boot and is running now. I wanted evidence of changes to identity files, sudo policy, SSH configuration, and firewall configuration. First I checked that the daemon existed and ran:

```bash
dpkg-query -W -f='${Status} ${Version}\n' auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

**If it is missing**, complete installation before enabling it:

```bash
sudo apt install auditd audispd-plugins
sudo systemctl enable --now auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

This ordering mattered in my lab: I initially tried to enable `auditd.service` before the package was installed, and the unit did not exist.

`apt install` adds the audit daemon and plugins; `enable --now` configures startup and starts the service immediately. The last two checks verify both states. Once installation completed, the service reported `enabled` and `active`.

Only then did I inspect the audit subsystem and rules: `auditctl -s` reports whether auditing is enabled and whether events are being lost; `auditctl -l` lists the rules currently active in the kernel. 

```bash
sudo auditctl -s
sudo auditctl -l
```

The active audit rules were initially empty, so I added persistent watches for account files, sudo policy, SSH configuration, and UFW. In each line, `-w` selects a path, `-p wa` watches writes and attribute changes, and `-k` assigns a searchable event key:

```text
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k privileged-access
-w /etc/sudoers.d -p wa -k privileged-access
-w /etc/ssh/sshd_config -p wa -k ssh-config
-w /etc/ssh/sshd_config.d -p wa -k ssh-config
-w /etc/ufw -p wa -k firewall
```

I checked the saved rule file, loaded the rules into the running kernel, then verified the active list and audit status before generating a test event:

```bash
sudo augenrules --check
sudo augenrules --load
sudo auditctl -l
sudo auditctl -s
```

After loading, `auditctl -l` showed the nine watches. The `identity` key grouped account-file events and `privileged-access` grouped sudo configuration; the other keys identified SSH and firewall changes. The status check later showed zero lost events and a backlog limit of 8192.

**Problem I encountered:** pasting `auditctl -s` twice onto one line produced “Too many options.” Running one clean status command fixed that input error. The separate status fields matter: `enabled 1` describes auditing state, while `lost 0` indicates no events lost at that check.

Next I inspected the log-retention settings, so the audit output would not grow without bounds:

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

The 8-MiB file limit and five-log rotation keep a bounded local history.

These settings control how often audit data is flushed, the log size and rotation count, and the actions taken when disk space is low or a write fails. The low-space/error actions define when logging warns or suspends; they do not provide central retention. These are the settings I inspected, not proof that I changed every one of them.

With the daemon and rules ready, I made a harmless test change: `touch` creates a temporary file under the watched firewall directory, `rm` deletes it, and `ausearch` looks for the corresponding audit events. 

```bash
sudo touch /etc/ufw/.audit-lab-test
sudo rm /etc/ufw/.audit-lab-test
```

I found creation and deletion records for the exact test path, with `touch` and `rm` in the process data and `key=firewall`. The earlier `CONFIG_CHANGE` event only showed that I added the rule; the later file events proved it captured activity.

For other watched configuration changes, I can use these focused queries:

Each `ausearch` command filters events by the identity, privileged-access, or SSH key. `ls` shows the audit log files and their sizes; `augenrules --check` checks that the saved rule files are consistent. 

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

My initial inspection found `send_redirects` and `accept_source_route` still enabled in the default/interface settings.

I saved the outgoing-redirect settings in a persistent sysctl file. The quoted heredoc writes the values literally, and `sysctl -p` applies them to the running kernel:

```bash
sudo tee /etc/sysctl.d/99-linux-hardening-network.conf >/dev/null <<'EOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.ens5.send_redirects = 0
EOF
sudo sysctl -p /etc/sysctl.d/99-linux-hardening-network.conf
```

The manual block replaced the whole named file, while the playbook writes additional host settings to the same path. On a playbook-managed rebuild, inspect its complete file and apply that instead of replacing it with this shorter historical block.

I subsequently corrected source-route acceptance too. The `all`, `default`, and `ens5` values read back as zero. I checked the live kernel values:

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

My corrected `all`, `default`, and `ens5` redirect/source-route settings read back as `0`.

The live-value check reloaded the saved file and read back kernel, filesystem, IPv4, and IPv6 controls. I checked both the `all` and interface/default values because they can differ. The resulting values and purposes were:

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

I checked for failed services, confirmed `rsyslog` was active, measured journal storage, and reviewed warnings since the start of the day:

```bash
systemctl --failed --no-pager
sudo systemctl is-active rsyslog
sudo journalctl --disk-usage
sudo journalctl -p warning --since today --no-pager
```

My checks found no failed units, `rsyslog` was active, and the systemd journal used 38.3 MiB. The warning output included boot-time virtual-hardware notices, a clock correction, IRQ-affinity messages, and a UFW block. In context, the UFW entry showed a denied packet, not accepted SFTP traffic.

The kernel also reported MDS/MMIO CPU notices.

These files show the kernel's current status for two CPU vulnerability mitigations; I checked the guest's reported state. I inspected the guest status with:

```bash
cat /sys/devices/system/cpu/vulnerabilities/mds
cat /sys/devices/system/cpu/vulnerabilities/mmio_stale_data
```

The guest reported attempted buffer clearing, no microcode, and unknown SMT host state. That output describes the guest's view and does not establish the state of AWS's underlying host. This inspection did not require changing SSH or firewall rules.

**Checkpoint:** I have reviewed host health, the evidence from each control, and any remaining messages. I can now test the actual file-transfer workflow.

## 4. Validation and cleanup

### 4.1 I obtained the server fingerprint before trusting the SFTP connection

The client key proves my transfer user's identity to the server.

`ssh-keygen` prints the target's public host-key fingerprint so I can verify the server before trusting the SFTP connection. The server's **host key** lets my client verify which server it reached. I checked the host fingerprint over the existing SSM management channel first.

I checked the target's SSH host-key fingerprint from its SSM session:

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

I reached the target's SFTP service through local port `2222` and compared the saved host-key fingerprint with the target fingerprint. The transfer and shell-denial commands follow below.

### 4.2 I uploaded and downloaded the text file, then compared its hashes

At the SFTP prompt in WSL, I entered the commands below without copying the prompt itself:

```text
sftp> get /upload/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
sftp> !sha256sum /tmp/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-test.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-downloaded.txt
```

The test file was uploaded into `/upload`.

`get` downloads the remote file to WSL, and `sha256sum` calculates hashes for the original and downloaded copies; matching hashes show the transfer preserved the content. The captured `get` command downloaded it to a different local filename, and `!sha256sum` compared the two copies on WSL. Both digests matched. 

The target-side destination was `/srv/sftp-data/upload/mds-sftp-test.txt`. Inside the chroot, that same location appeared as `/upload/mds-sftp-test.txt`. The successful transfer proved this file could make the round trip intact.

### 4.3 I tested actions the transfer account should be denied

A successful upload proves usability. It does not prove the user is restricted, so I also tested the boundaries.

The captured SFTP output refused opening `/mds-write-denied-test.txt` with `Permission denied`. That demonstrates the transfer account could not write at the chroot root. 

**Back in the WSL shell, with the SSM tunnel still open:**

```bash
ssh -T -p 2222 -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes sftpdata@127.0.0.1 id
```

My response was `This service allows sftp connections only.

`This `ssh` attempt asks to run `id` through the tunnel; the server's SFTP-only response confirms the account cannot start a shell. That was the intended denied-shell result, not an SSH service failure. The account could transfer a file but could not run `id` as a shell command.

I also compared the saved host-key fingerprint with the one I obtained through SSM: `ssh-keygen -F` retrieves the saved host key for the local tunnel address, and the second command formats it as a SHA-256 fingerprint for comparison with the target's verified fingerprint. 

```bash
ssh-keygen -F '[127.0.0.1]:2222' | ssh-keygen -lf - -E sha256
```

**Checkpoint:** transfer succeeded within `/upload`, a chroot-root write failed, shell execution was denied, and the server identity matched.

### 4.4 What the tests showed

| Check | Result |
| --- | --- |
| Management path | Both private EC2 nodes were managed with SSM; no public IP or inbound security-group rule |
| Account boundary | Dedicated key, SFTP-only identity, root-owned chroot and restricted writable child directory |
| Transfer | `mds-sftp-test.txt` uploaded and downloaded; SHA-256 values matched |
| Denied actions | Chroot-root write and shell command were refused |
| Host firewall | UFW active, default deny incoming, allow outgoing; new SSM and tunneled SFTP access still worked |
| Host monitoring | auditd active, nine watches loaded, harmless test events captured, zero lost events at status check |
| Maintenance and host settings | AppArmor/service state, update results, persistent sysctls, logs, and failed units inspected |

I kept the [verification record](verification.md) and [hardening evidence](../evidence/hardening-results.md) alongside the code. I also worked through several problems: the wrong WSL PATH, missing CLI profile, host confusion, an auditd unit checked before installation, and pasted commands accidentally joined together. Each taught me to check a prerequisite or the actual source of an output before changing policy.

### 4.5 I removed the temporary files and destroyed the AWS infrastructure

To finish the demonstration, I closed the SFTP and tunnel sessions and exited the EC2 shells. I then returned to the WSL project directory that held the Terraform configuration and state before removing the running resources.

My first destroy attempt encountered `BucketNotEmpty`. The bucket still contained `sftpdata/sftpdata.pub`. I removed the remaining contents and retried Terraform.

```bash
cd ~/mds-aws-linux-hardening-1b
terraform destroy
terraform state list
```

I ran the destroy from the original Terraform working directory and reviewed its proposed deletions.

`cd` selects the directory containing the original Terraform state. `terraform destroy` proposes removal of the managed lab resources and asks for confirmation; `terraform state list` checks which resources remain in that state. 

After removing the bucket contents, Terraform reported `Destroy complete! Resources: 1 destroyed.

` That was the last resource from the earlier partial teardown. `terraform state list` was empty afterward.

### 4.6 I checked AWS service state after Terraform finished

An empty Terraform state shows what that state file still manages; I also checked AWS. These queries use the deployment IDs and project tag, so there is no need to look up old outputs after destroy:

The tagging query returned old resource ARNs, which prompted direct service checks:

This query lists ARNs still returned by the project tag filter, so I could compare those results with each service's actual resource state. 

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=mds-linux-hardening-1b \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output table \
  --profile mds-devsecops-lab \
  --region us-east-1
```

The AWS checks showed instance and NAT states, an endpoint-ID not-found response, and a volume-ID not-found response. A subsequent filtered volume check returned no resources. 

The S3 verification command is preserved in the chat:

This query checks whether the lab bucket name still appears in the account's bucket list. 

```bash
aws s3api list-buckets \
  --query "Buckets[?Name=='mds-linux-hardening-1b-273517699789-us-east-1'].Name" \
  --output text \
  --profile mds-devsecops-lab \
  --region us-east-1
```

My checks showed both instances `terminated`, the NAT Gateway `deleted`, the queried endpoint absent, and no volumes in the filtered volume result. Deleted instances can remain visible briefly; later their IDs can return not found. The tagging API still listed old ARNs, which did not override the direct service states. My S3 listing could not reach its endpoint at that time, so I treated the Terraform deletion separately from that unavailable check.

**Final checkpoint:** Terraform state is empty, and direct service checks showed no active lab resources in the queried scope. I finished the demonstration by tearing down the infrastructure and keeping the configuration available to repeat the work.

