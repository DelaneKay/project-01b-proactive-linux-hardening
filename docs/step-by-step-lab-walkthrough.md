# Project 1B — Proactive Linux server hardening walkthrough

This walkthrough documents the Project 1B lab from its design decisions through validation and teardown. It is based on the saved learning journal and the outputs captured during the run. The aim is to make the work reproducible and explain what each control was meant to accomplish, what evidence demonstrated it, and what the evidence does not prove.

> **Reconstruction note:** The Terraform configuration in this repository is the source used for the deployment. The temporary Ansible playbook used during the lab was not retained. `ansible/playbooks/harden-target.yml` is a reconstruction of the verified target configuration, not a byte-for-byte copy of the original playbook. It passed a syntax check; the original successful Ansible run is recorded in the journal (17 ok, 3 changed, 0 unreachable, 0 failed). Do not represent the reconstructed playbook as the exact artifact that produced that run.

## 1. Lab objective and security problem

Project 1A investigated and remediated a server that already had problematic settings. Project 1B took the proactive approach: build a small private AWS environment, configure a Linux file-transfer workload with least privilege from the start, test both its allowed and denied behaviors, and then destroy the lab.

The fictional workload was a private SFTP drop for synthetic customer-register data. The security problem was to provide a practical file-transfer path without giving a transfer user an interactive shell, access to the rest of the filesystem, write access outside its upload area, or a public SSH endpoint. A network boundary alone would not establish those host-level guarantees. The project combined private AWS networking and Session Manager access with Linux identity, OpenSSH, filesystem, firewall, audit, and kernel-network controls.

The lab used synthetic data only. It was not a production deployment or a real customer-data service.

## 2. Design and architecture

The operator's workstation ran Terraform and AWS CLI. An EC2 admin node ran Ansible and managed the target through the AWS Systems Manager (SSM) connection plugin. Both EC2 instances were private and had no public IP addresses or inbound security-group rules. The target's local `sshd` still listened on port 22; administrators and the SFTP test reached it through SSM, not through an Internet-facing SSH rule.

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

| Component | Recorded configuration | Why it was used |
| --- | --- | --- |
| Region and AZ | `us-east-1`, one AZ (`us-east-1a`) | Small, cost-conscious single-AZ lab |
| VPC | `10.20.0.0/16` | Isolated address space for the exercise |
| NAT subnet | `10.20.0.0/24` | Hosts the NAT Gateway for outbound updates and required service traffic |
| Admin subnet | `10.20.10.0/24`, private | Runs Ansible without public ingress |
| Target subnet | `10.20.20.0/24`, private | Hosts the SFTP server without public ingress |
| Instances | Ubuntu Server 24.04 LTS; admin `t3.small`, target `t3.micro` | 2 GiB controller memory for Ansible; smaller target for the light workload |
| Storage | Encrypted 20-GiB gp3 root volumes; encrypted 5-GiB gp3 target data volume | Explicit encryption because regional EBS encryption-by-default was off; separate workload data from the OS |
| Management | SSM Session Manager, no inbound SG rules | IAM-authenticated administration without a public bastion or SSH ingress |
| Ansible transfer | Private encrypted S3 bucket with lifecycle cleanup and S3 Gateway endpoint | The SSM Ansible connection plugin temporarily transfers module content through S3 |
| Instance IAM | Custom minimal SSM agent channel policy; separate, scoped controller permissions | Avoid broad administrator permissions and separate agent duties from controller duties |

The NAT Gateway was a deliberate lab trade-off: it costs more per hour than a NAT instance, but avoids adding another Linux server to patch and operate. One NAT Gateway in one AZ is a cost-saving lab design, not a highly available production pattern. The SFTP account was also deliberately separate from the administrative identity: a file-transfer key should not imply `sudo` or operating-system control.

### 2.1 Follow the management and data paths

There were two distinct uses of SSM in this design:

1. **Administration:** the workstation asked Systems Manager to start a shell session to the admin or target node. The SSM Agent on the instance opened outbound control/data channels; the operator did not connect to port 22 on the instance from the Internet.
2. **SFTP test:** the workstation asked SSM to forward local port `2222` to target port `22`. The SFTP client connected to `127.0.0.1:2222`, while the target still handled a normal SSH/SFTP protocol session locally.

Ansible used a third, related path: its controller process on the admin node asked SSM to run commands on the target, and its connection plugin staged temporary module files through the private S3 bucket. The S3 Gateway endpoint gave VPC traffic a path to S3 without sending that bucket traffic through a public internet route. These mechanisms solve different problems: SSM provides an authenticated management channel, S3 stages Ansible payloads, and the target's OpenSSH server enforces the Linux SFTP policy.

The security groups and host firewall are also separate enforcement layers. A listener on target port 22 is necessary for SFTP, but does not by itself make the service reachable from an untrusted network. The EC2 security group had no inbound rules; UFW on the target added a host-level deny-incoming policy. SSM port forwarding was the intentionally authorized path used in the lab.

## 3. Prepare and provision the AWS lab

### 3.1 Confirm the operator identity and configuration

The commands below were run from the WSL project directory on the workstation. The profile name in the recorded lab was `mds-devsecops-lab`; use your own authorized lab profile when reproducing the project. Confirm the identity before any change so the plan and apply run under the account you intend.

```bash
cd ~/mds-aws-linux-hardening-1b
aws sts get-caller-identity --profile mds-devsecops-lab
terraform version
aws --version
```

The journal recorded Terraform 1.16.6 and AWS CLI v2.38.3 on WSL. An early `aws --version` check returned “command not found” when run as the non-root `devsecops` user even though the CLI was available in a different shell context. The resolution was to run the checks and Terraform as the ordinary `devsecops` user with its configured profile and PATH, rather than confusing that local WSL environment with either EC2 node. The target itself was a separate Ubuntu 24.04.5 EC2 host; WSL later reported Ubuntu 26.04 on a Microsoft WSL2 kernel. Always confirm the current shell and host before interpreting package, kernel, or firewall results.

The AWS CLI was installed under the WSL user's local directory. When the executable exists but `aws` is not found in a fresh shell, the journal's PATH fix was:

```bash
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
aws --version
```

The first line fixes the current shell; the `.bashrc` line makes the change persist for new interactive Bash shells. The recorded executable was `/home/devsecops/.local/bin/aws`. Do this as the intended WSL user, not as root, so the CLI and AWS login cache remain in the same home directory.

The recorded workstation used AWS CLI browser sign-in for temporary credentials. If the profile's session has expired, authenticate interactively, then verify both the AWS principal and Region before provisioning:

```bash
aws login --profile mds-devsecops-lab
aws sts get-caller-identity --profile mds-devsecops-lab \
  --query Arn --output text
aws configure get region --profile mds-devsecops-lab
aws iam list-mfa-devices --user-name mds-devsecops-lab \
  --query 'length(MFADevices)' --output text
```

The journal confirmed that the CLI identity was the named IAM lab user, the Region was `us-east-1`, and one MFA device was attached. Do not paste the full ARN/account ID, browser authorization values, password, MFA seed, QR image, or one-time codes into documentation. The lab user had broad `AdministratorAccess` during this exercise; that was a human operator permission choice, not an instance role. For a production or portfolio reproduction, prefer a role or IAM Identity Center permission set scoped to the deployment, and avoid account-wide administrator access where practical.

For completeness, the journal's one-time IAM-user bootstrap used these commands while signed in as an already-authorized AWS administrator. They are **historical lab setup commands**, not commands to run for every deployment; a managed workforce role or IAM Identity Center is preferable where available:

```bash
aws iam create-user --user-name mds-devsecops-lab
aws iam attach-user-policy --user-name mds-devsecops-lab \
  --policy-arn arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess
aws iam attach-user-policy --user-name mds-devsecops-lab \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam list-attached-user-policies --user-name mds-devsecops-lab
```

The user also enrolled a virtual MFA device and verified it without printing its serial or one-time codes:

```bash
aws iam list-mfa-devices --user-name mds-devsecops-lab \
  --query 'length(MFADevices)' --output text
```

The recorded result was `1`. `SignInLocalDevelopmentAccess` enables browser-based CLI sign-in; it does not itself grant EC2 or S3 permissions. `AdministratorAccess` granted the human lab operator those broad permissions in this particular exercise. Neither policy belongs on an EC2 instance profile. The journal's MFA QR image, password, and TOTP values are intentionally not reproduced.

### 3.2 Inspect the Terraform project and plan

The repository contains the Terraform resources, provider lock file, example variables, and outputs. Copy the example variable file locally and fill only values needed for your own deployment. Do not commit real `terraform.tfvars`, state files, credentials, private keys, or account-specific output.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
export AWS_PROFILE=mds-devsecops-lab
aws sts get-caller-identity
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
```

Read the full plan before applying. Confirm the region, network ranges, instance types, IAM policy scope, encrypted volumes, absence of public IPs, and absence of ingress rules. The journal records explicit EBS encryption because the account's regional encryption-by-default setting was disabled. The Ubuntu 24.04 AMI was looked up through Canonical's public SSM parameter and its owner, architecture, state, and image name were checked before use. The checked image was Canonical-owned (`099720109477`), `x86_64`, and Ubuntu Noble.

The journal also kept the read-only AWS preflight queries that informed those Terraform choices. These are useful before writing or applying the configuration, because CIDR overlap, unavailable instance types, an incorrect image publisher, or an assumed EBS encryption default can invalidate a plan:

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

The recorded existing default VPC used `172.31.0.0/16`; the lab selected non-overlapping `10.20.0.0/16`. Six AZs were listed and `us-east-1a` was selected for the single-AZ lab. All candidate T2/T3 sizes checked were offered there. Canonical's AMI owner ID was `099720109477`; the image was available and `x86_64`. The regional EBS encryption-by-default result was `false`, and the AWS-managed EBS key alias was `alias/aws/ebs`. Those account-level values were inspected but not changed; Terraform explicitly requested encryption for project volumes.

Cost was also part of the design decision. The journal's October 2026 estimate put one continuously running NAT Gateway at about `$32.85/month`, before data processing, and the two EC2 instances at about `$22.85/month`, before storage and networking extras. That baseline could exceed the learner's `$50` monthly budget notification. Prices change, and a budget alert only notifies; it does not cap spend. The practical control was to run the lab only when needed and destroy it afterward.

```bash
terraform apply
terraform output
cd ..
```

Terraform outputs provide the admin and target instance IDs and transfer bucket name. Keep those values in the shell or an untracked local file; do not paste live identifiers into public documentation. Wait until both nodes are registered as SSM managed instances before proceeding. If a node does not appear, check its instance profile, SSM Agent status, route to the required SSM endpoints, and NAT or VPC endpoint path instead of opening inbound SSH as a shortcut.

### 3.3 Open the admin Session Manager session

From the workstation, start a session to the admin node:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw admin_instance_id)" \
  --profile "$AWS_PROFILE" --region us-east-1
```

An SSM session is initiated through AWS APIs and the SSM Agent's outbound channels. The instance does not need a public address or an inbound SSH rule. On the admin node, install Ansible, the Session Manager plugin, and the collections listed in `ansible/requirements.yml`. Check the SSM connection plugin's documented requirements and confirm the target is online before running Ansible.

The controller uses `amazon.aws.aws_ssm`. Its module transfers use the configured private S3 bucket, so the admin role needs bucket-scoped transfer permissions and the target must be able to reach S3 using the configured path. The target agent role has only the five selected SSM channel actions; the admin controller's session and bucket permissions are separate. Do not replace these roles with `AdministratorAccess` to make a connection problem disappear.

The journal records why the instance policy was narrowed instead of attaching the broader `AmazonSSMManagedInstanceCore` policy. That managed policy included parameter, patching, inventory, and compliance actions the lab did not require. The selected instance-agent policy had five Session Manager actions:

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

This is the **instance agent** permission set, not the human operator policy and not the Ansible controller policy. The controller additionally needs permission to start and terminate the target session and access only the transfer bucket. Its recorded S3 actions were `s3:GetObject`, `s3:PutObject`, `s3:ListBucket`, `s3:DeleteObject`, and `s3:GetBucketLocation`, scoped to the lab bucket and its objects. Do not attach the human IAM user's administrator policy to either EC2 role.

### 3.4 Configure inventory and the SFTP public key

The EC2 nodes did not need Git or GitHub authentication. For a reproduction from this repository, stage the reviewed Ansible files in the private transfer bucket, then retrieve them on the admin node. Run the first block from the workstation at the repository root, and the second inside the admin SSM session:

```bash
# Workstation: upload the Ansible source tree, excluding any local secret inventory.
aws s3 cp ansible/ \
  "s3://$(terraform -chdir=terraform output -raw ansible_transfer_bucket)/project-1b/ansible/" \
  --recursive --exclude 'inventory/hosts.yml' \
  --profile "$AWS_PROFILE" --region us-east-1

# Admin EC2: retrieve only the reviewed project Ansible files.
mkdir -p ~/project-1b
aws s3 cp "s3://YOUR_TRANSFER_BUCKET/project-1b/ansible/" \
  ~/project-1b/ansible/ --recursive --region us-east-1
cd ~/project-1b
```

Replace `YOUR_TRANSFER_BUCKET` in the admin command with the Terraform output. This is a transfer mechanism for the private lab, not a reason to make the bucket public. The operator's S3 action uses its authenticated profile; the admin node uses its instance role. The role's object permissions should be limited to this bucket/prefix. Remove temporary objects at teardown.

On the admin node, copy `ansible/inventory/hosts.example.yml` to an untracked `ansible/inventory/hosts.yml`. Set the target instance ID, Region, transfer bucket, and SFTP public-key path. Keep account-specific inventory out of version control. Install the declared collections and the Ansible/SSM connection prerequisites before running the playbook.

The dedicated Ed25519 SFTP key pair was generated on the operator workstation. Its private key remained there; only the public key was uploaded as `sftpdata/sftpdata.pub` to the private transfer bucket. The admin node retrieved that public key to `/tmp/sftpdata.pub` using its instance role and supplied it to Ansible. Do not place the private key in S3, on the target, in Terraform state, or in the repository.

This command sequence reproduces the key-staging flow. Run the first two commands on the workstation and the final download on the admin node. Replace `YOUR_TRANSFER_BUCKET` with the Terraform output in your active shell; the private key is never uploaded.

```bash
# Workstation: create the dedicated key pair with a private local key file.
umask 077
ssh-keygen -t ed25519 \
  -f ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -C "project-1b-sftpdata"

# Workstation: stage only the public key in the private lab bucket.
aws s3 cp ~/.ssh/mds-linux-hardening-1b-sftpdata.pub \
  "s3://YOUR_TRANSFER_BUCKET/sftpdata/sftpdata.pub" \
  --profile "$AWS_PROFILE" --region us-east-1

# Admin EC2: retrieve the public key using the instance role.
aws s3 cp "s3://YOUR_TRANSFER_BUCKET/sftpdata/sftpdata.pub" \
  /tmp/sftpdata.pub --region us-east-1
chmod 0644 /tmp/sftpdata.pub
```

`ssh-keygen` prompts for a passphrase; do not record or share it. The journal recorded the target account as UID/GID 1002, but a reusable playbook should use `sftpdata` and `sftp-only` names instead of hard-coding those numbers.

The initial SSM transfer path required troubleshooting: the Ansible plugin uses temporary S3 transfers, so a working SSM session by itself does not prove Ansible can stage its module. Verify plugin and collection installation, bucket name and permissions, target reachability to S3, and controller role before changing network exposure. The final Ansible run recorded in the journal completed with `ok=17`, `changed=3`, `unreachable=0`, and `failed=0`.

## 4. Inspect the target before changing it

Start a second SSM session directly to the target for baseline inspection and final verification:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw target_instance_id)" \
  --profile "$AWS_PROFILE" --region us-east-1
```

Commands in this section run **inside the target's SSM shell**, unless otherwise marked. Record the hostname, OS release, kernel, package state, services, listeners, and current control state. These checks prevent applying target-hardening assumptions to the workstation or admin node.

```bash
hostname
cat /etc/os-release
uname -r
systemctl list-units --type=service --state=running --no-pager
ss -lntup
```

The recorded target was `ip-10-20-20-177`, Ubuntu 24.04.5 LTS, on an AWS kernel. The listener inventory included SSH on IPv4 and IPv6 wildcard addresses, local DNS resolver sockets, and chrony. This was not equivalent to public reachability: the security groups had no inbound rules and the instance had no public IP. SFTP would be tested through SSM port forwarding.

The journal also recorded the state of the relevant security controls before and after work. UFW was initially inactive; the kernel firewall policy showed default ACCEPT chains. AppArmor was enabled and active, with 122 profiles loaded and 26 in enforce mode. The unattended-upgrades service was active and enabled after correcting a malformed combined command that had obscured its output. These checks illustrate why commands should be run separately and why a command's pasted output must be attributed to the correct host.

To inspect patch state and reboot requirements:

```bash
apt list --upgradable 2>/dev/null
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo "No reboot is currently required"
fi
```

Four Ubuntu packages were reported as upgradable but deferred due to phased rollout: `cloud-init`, `tmux`, `ubuntu-pro-client`, and `ubuntu-pro-client-l10n`. The lab did not force phased updates. At the recorded check, no reboot was required. An enabled `unattended-upgrades` service does not mean every available update installs immediately; review its allowed origins and logs when investigating update behavior.

### 4.1 Prepare the separate target data volume

This step must be completed before the reconstructed playbook runs, because its first task asserts that `/srv/sftp-data` is already a mount point. The journal confirms the resulting device was ext4 and was persistently mounted by UUID with `defaults,nofail`; it did not preserve the exact original format/mount command transcript. The following is a safe reproduction for a **new, empty lab volume only**.

First identify the attached 5-GiB volume and confirm it is not mounted and has no filesystem/data that needs to be preserved:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
sudo blkid
```

The recorded device name was `/dev/nvme1n1`; device numbering can differ, so verify rather than copy that name blindly. Only after confirming the correct disk is blank, create the filesystem and mount point:

```bash
sudo mkfs.ext4 /dev/nvme1n1
sudo install -d -o root -g root -m 0755 /srv/sftp-data
sudo blkid /dev/nvme1n1
```

Copy the UUID from `blkid`. Check for an existing entry to avoid adding duplicates, then use `sudoedit /etc/fstab` to add one line with the actual UUID:

```text
UUID=REPLACE_WITH_FILESYSTEM_UUID /srv/sftp-data ext4 defaults,nofail 0 2
```

The duplicate check is:

```bash
grep -nF '/srv/sftp-data' /etc/fstab || true
```

Mount and verify before proceeding:

```bash
sudo mount /srv/sftp-data
findmnt --mountpoint /srv/sftp-data
df -hT /srv/sftp-data
```

Expected: filesystem type `ext4`, mount point `/srv/sftp-data`, and the source matching the new volume's UUID. Do not rerun `mkfs` on an existing filesystem. The committed playbook does **not** format a disk, write `/etc/fstab`, or mount it; it checks the mount and stops if it is missing. Keeping destructive disk initialization separate from routine hardening prevents a playbook rerun from erasing data.

## 5. Apply the target's host hardening

The committed playbook is `ansible/playbooks/harden-target.yml`. It represents the final intended host settings and organizes them into repeatable tasks. Because it was reconstructed after the original temporary file was lost, use it as a reviewed reproduction starting point and inspect its variables and handlers before deployment.

On the admin node, install the declared collections and run the syntax check, then apply against the target inventory:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml --syntax-check
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml
```

The hardening included these outcomes:

1. **Separate SFTP identity:** user `sftpdata`, group `sftp-only`, UID/GID 1002 in the recorded run, locked password, and `/usr/sbin/nologin` shell.
2. **Chrooted OpenSSH:** the `sftpdata` match block uses the internal SFTP subsystem, disables forwarding and interactive shell capability, and confines the account to `/srv/sftp-data`.
3. **Dedicated data filesystem:** the separate encrypted 5-GiB gp3 EBS device was formatted as ext4, mounted by UUID at `/srv/sftp-data` with `defaults,nofail`, and used independently of the root filesystem.
4. **Safe chroot ownership:** `/srv/sftp-data` remained `root:root` mode `0755`, as required by OpenSSH; `/srv/sftp-data/upload` was `sftpdata:sftp-only` mode `0750` and was the only writable transfer location.
5. **Key-only access:** `/home/sftpdata/.ssh` was mode `0700`; `authorized_keys` was owned by the transfer identity and mode `0600`. Password login was disabled for this SFTP identity.
6. **Firewall and host controls:** UFW was configured with deny incoming, allow outgoing, IPv6 enabled, and low logging. AppArmor and unattended-upgrades service state was checked. Auditd policy and rules, plus persistent kernel/network sysctls, were installed.

### 5.1 Understand the SSH policy that enforces SFTP-only access

The reconstructed playbook installs a dedicated drop-in file at `/etc/ssh/sshd_config.d/00-project-hardening.conf`. Its intended policy is shown below. This excerpt documents the repository's reconstructed configuration, not a preserved copy of the temporary file from the original run:

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

The global directives disable root login and password-based authentication while allowing public-key authentication. The group match applies the chroot and `internal-sftp` forced command to members of `sftp-only`; `-d /upload` makes the client start in the writable upload directory. Forwarding, tunnel, TTY, and X11 capabilities are disabled for the restricted account. `Match all` closes the conditional block so later SSH settings are not accidentally scoped to that group.

OpenSSH checks ownership and permissions on every component of `ChrootDirectory`. It must be owned by root and cannot be writable by group or other users. That is why the chroot itself is root-owned and the user can write only to a child directory. Making the chroot root writable would violate OpenSSH's safety requirement and undermine the confinement boundary. The SFTP account has a locked password and `nologin` shell as additional controls; the forced internal SFTP command is what constrains the SSH session to the file-transfer subsystem.

Before installing an SSH change, validate the candidate file and then validate the effective configuration. The playbook's copy task uses `sshd -t` as its validation command, so an invalid file is rejected before replacement. A safe manual review sequence is:

```bash
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1 \
  | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|forcecommand|chrootdirectory|allowtcpforwarding|permittty)'
```

`sshd -t` checks syntax. `sshd -T -C` evaluates the effective settings for a connection context, including `Match` rules; it is stronger evidence than reading a file in isolation. During the lab, the first effective-config query was blocked because `/run/sshd` was missing. Creating that runtime directory allowed the check to proceed. If the command fails on another system, inspect its exact error and service/runtime state before changing authentication policy.

The data device was confirmed before formatting. Formatting an unverified block device is destructive; on a reproduction, identify the attached volume and confirm it is the intended empty lab disk before issuing any filesystem command. The playbook should be reviewed for idempotence and for SSH configuration validation (`sshd -t`) before installation. Do not add an inbound UFW or security-group allow rule for TCP 22; SSM provides the management and test tunnel.

### 5.2 Inspect the filesystem, identity, and effective SSH result

After Ansible completes, use these read-only checks in the target's SSM shell. They connect the intended policy to the actual filesystem and account state:

```bash
lsblk -f
findmnt --mountpoint /srv/sftp-data
getent passwd sftpdata
id sftpdata
namei -l /srv/sftp-data/upload
stat -c '%U:%G %a %n' \
  /srv/sftp-data \
  /srv/sftp-data/upload \
  /home/sftpdata/.ssh \
  /home/sftpdata/.ssh/authorized_keys
```

`lsblk -f` identifies block devices, filesystem type, and UUID; `findmnt` confirms the dedicated filesystem is mounted at the expected chroot path. The expected account has the restricted group, `nologin` shell, and no administrative group membership. `namei -l` walks every parent directory and exposes an unsafe owner or mode in the path, while `stat` checks the final objects. The recorded directory policy was chroot root `root:root 755`, upload directory `sftpdata:sftp-only 750`, `.ssh` `sftpdata:sftp-only 700`, and `authorized_keys` `sftpdata:sftp-only 600`.

The effective SSH settings should be tested for the restricted account, not inferred from the global file alone:

```bash
sudo install -d -o root -g root -m 0755 /run/sshd
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1 \
  | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|forcecommand|chrootdirectory|allowtcpforwarding|permittty)'
```

The `install -d` line recreates the runtime directory that was missing during the recorded manual check; it does not change the persistent SSH policy. On a system where the service manager already created `/run/sshd`, it should already exist. `sshd -T -C` should show the effective chroot and forced internal-SFTP command for this user, with forwarding and TTY disabled. If output differs, inspect drop-ins and `Match` ordering before testing with the account.

## 6. Validate SFTP's allowed and denied behavior

### 6.1 Start the SSM port-forwarding tunnel

From the workstation, open a port-forwarding session to the target's local SSH service. Leave this terminal open while testing from another terminal.

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw target_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}' \
  --profile "$AWS_PROFILE" --region us-east-1
```

This maps workstation `127.0.0.1:2222` through SSM to target port 22. It does not create an inbound network rule. The tunneled SSH/SFTP payload is encrypted; SSM session start/stop records do not expose tunneled filenames or file contents.

### 6.2 Check the server host key and authenticate with SFTP

In another workstation terminal, connect with the dedicated private key:

```bash
sftp -P 2222 -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes sftpdata@127.0.0.1
```

The SSH host key shown through the local tunnel should be verified against the target's public host-key fingerprint, obtained through the trusted SSM administration channel. The journal compared the ED25519 fingerprint in the workstation's `[127.0.0.1]:2222` known-host entry with the target's `/etc/ssh/ssh_host_ed25519_key.pub`; they matched. This checks that the tunnel terminates at the expected target instead of silently trusting an unknown host key.

The comparison commands used were:

```bash
# Workstation: fingerprint of the host key learned through the local SSM tunnel.
ssh-keygen -F '[127.0.0.1]:2222' | ssh-keygen -lf - -E sha256

# Target SSM shell: fingerprint of the target's actual ED25519 public host key.
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Compare the `SHA256:` fingerprint strings. The host key is distinct from the SFTP user's client key: the client private key proves the user's identity to the server; the server host key lets the client verify which server it reached.

The recorded session opened at `/upload`. The test created a harmless local file, uploaded it to `/upload`, downloaded it to a different local path, and compared SHA-256 digests. From the SFTP prompt, `!` runs a local workstation command (it does not run a command on the target):

```text
sftp> !printf 'SFTP hardening lab transfer test\n' > /tmp/mds-sftp-test.txt
sftp> put /tmp/mds-sftp-test.txt /upload/mds-sftp-test.txt
sftp> get /upload/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
sftp> !sha256sum /tmp/mds-sftp-test.txt /tmp/mds-sftp-downloaded.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-test.txt
d138cba463fc98be7e2c7692f969a71d0a4c17c095462a4e76ca03582535090e  /tmp/mds-sftp-downloaded.txt
```

`put` sends the local source to the server path; `get` retrieves that server path to a different local filename. Equal SHA-256 values demonstrate byte-for-byte integrity for this test transfer. They do not establish the provenance or safety of arbitrary files; the exercise uses a harmless synthetic text file rather than real customer data.

Matching hashes showed the downloaded bytes matched the uploaded test file. The test then checked the boundaries:

| Test | Recorded behavior | What it demonstrated |
| --- | --- | --- |
| Upload and download in `/upload` | Both succeeded; SHA-256 digests matched | The intended file-transfer workflow worked end to end |
| Move above the chroot (`cd ..`) | SFTP remained at `/` | The SFTP client could not traverse above its chroot view |
| Access the target's real `/etc` | Not available inside the SFTP view | The transfer identity did not see the host's real root filesystem |
| Upload into chroot root (`/`) | `Permission denied` | The chroot root was not writable; writes were limited to its upload child |
| Attempt remote shell (`ssh -T ...`) | `This service allows sftp connections only.` | The identity was restricted to the SFTP subsystem rather than an interactive shell |

The SFTP-client-side negative checks can be run in the same session after a successful upload/download:

```text
sftp> pwd
sftp> cd ..
sftp> pwd
sftp> cd /etc
sftp> put /tmp/mds-sftp-test.txt /mds-write-denied-test.txt
```

The expected path remains at the chroot view `/` after `cd ..`; `/etc` refers to a path inside that restricted view, not the host's real `/etc`. The upload to `/` should fail with `Permission denied` because only `/upload` is writable. To test shell denial, leave SFTP and run from the workstation:

```bash
ssh -T -p 2222 \
  -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes \
  sftpdata@127.0.0.1
```

The expected response is `This service allows sftp connections only.` This is a successful negative test when the transfer-only account cannot obtain a shell; it is not a failed SSH daemon.

The early test used `/upload` as the SFTP-visible path even though its target-side directory was `/srv/sftp-data/upload`. Chroot path translation is intentional: inside the restricted session, `/` corresponds to `/srv/sftp-data`, while `/upload` maps to the writable child directory.

### 6.3 Troubleshoot connection failures without weakening the boundary

The journal records several issues that are useful to recognize:

- `ssh -T` returning “This service allows sftp connections only” was the expected denied-shell result, not a failed SFTP configuration.
- Uploading to `/` returned `Permission denied` by design. Use `/upload` for transfers; do not loosen chroot-root ownership to make the root writable.
- Host-key fingerprints should be compared through the SSM management channel. Do not disable host-key checking as a routine fix.
- A successful SSM shell does not by itself prove that the Ansible SSM plugin can stage its temporary S3 files. Check plugin prerequisites and bucket permissions separately.
- `sshd -T` initially could not run because `/run/sshd` did not exist. The runtime directory was created, after which the effective configuration could be checked. This is an ephemeral runtime prerequisite, not a reason to edit SSH policy blindly.
- Some transcript output was accidentally concatenated (for example, `systemctl` checks, UFW status, and command text without separators). Re-run one command at a time and confirm the hostname before recording conclusions.

## 7. Verify operating-system controls

Run these checks in the **target's SSM shell**, not the workstation or admin node. Capture sanitized output and avoid publishing account IDs, internal addresses, access keys, or private key material.

### 7.1 Network firewall and listening services

```bash
sudo ufw status verbose
sudo ufw status numbered
sudo ss -lntup
sudo iptables -S
sudo ip6tables -S
```

The final UFW state was active, logging low, default deny incoming, allow outgoing, and disabled routed traffic. IPv6 support was enabled in UFW configuration. No explicit inbound SSH allow rule was added. The systemd socket/listener inventory still showed local SSH on port 22, but the EC2 security groups had no inbound rules. A process listening on an interface and a port reachable from the Internet are different facts; check both host and cloud network controls.

The firewall change intentionally did not add an SSH exception. That preserved a simple rule: unsolicited inbound traffic is denied by the host, while the lab's management and SFTP test use SSM. Outbound traffic remained allowed so the instance could use its expected update and management paths. UFW's “active” status confirms it is enforcing its configured policy; it does not prove that every cloud route or security group is correct. Conversely, the earlier `iptables -S` output showing ACCEPT base policies was collected before UFW was enabled and must not be used as the final firewall result. The final evidence used UFW status and successful SSM/SFTP tests together.

The first `ufw status numbered` attempt returned usage text because the command had accidentally been concatenated with `IPV6=yes`. Re-running it alone produced the status output. The earlier `ufw: command not found` result belonged to the WSL host, where UFW was not installed; it was not evidence about the AWS target. This is why host identity and clean command boundaries matter in a multi-node lab.

These are the standalone commands used to establish the recorded UFW policy on the target. The Ansible playbook expresses the same intent declaratively:

```bash
sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

`--force` avoids an interactive confirmation, which is useful for automation; use it only after verifying a recovery path. SSM was already working and did not depend on inbound SSH. The sequence intentionally does not add `ufw allow 22/tcp`. If a future deployment manages the host only over SSH, enabling deny-incoming without a verified alternate management path can lock out the operator. The recorded project enabled UFW and then confirmed that new SSM and tunneled SFTP sessions still worked.

### 7.2 AppArmor and unattended upgrades

```bash
sudo aa-status
systemctl is-enabled apparmor
systemctl is-active apparmor
systemctl is-enabled unattended-upgrades
systemctl is-active unattended-upgrades
sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
```

The target reported AppArmor enabled and active. At the recorded status check, 122 profiles were loaded, with 26 enforcing; `chronyd` and `rsyslogd` were among the enforced processes. The SSM Agent profile was in complain mode in the recorded output. This status command reports policy state; it does not prove that every workload has a tailored enforcing profile.

The unattended-upgrades unit was enabled and active. Its log listed allowed Ubuntu Noble updates and security origins and reported that no unattended packages were ready at that particular check. A separate package listing showed four updates deferred due to phased rollout; the lab left phasing intact rather than forcing those packages.

### 7.3 Auditd installation, rules, and event test

Auditd was not installed at the initial package check. Installing `auditd` and `audispd-plugins` created the service unit. The first `systemctl enable --now auditd` attempt failed because the package installation had not completed yet. After installation completed, the command succeeded and both `systemctl is-enabled auditd` and `systemctl is-active auditd` returned `enabled` and `active`.

The corrected manual package/service order is:

```bash
sudo apt-get update
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

Do not run the service-enable command until package installation has finished and the unit file exists. In the recorded sequence, the installation completed successfully, created the unit, and then enabling/starting it succeeded.

Check the audit daemon and loaded rules:

```bash
sudo auditctl -s
sudo augenrules --check
sudo auditctl -l
```

The active rules watched identity, privilege, SSH, and firewall configuration paths for writes and attribute changes:

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

In each watch, `-w` monitors the named file or directory, `-p wa` selects write and attribute-change activity, and `-k` attaches a searchable key. For example, the `privileged-access` key groups changes to `/etc/sudoers` and `/etc/sudoers.d`; `identity` groups account database files. The rules record that a relevant filesystem operation occurred, along with process and syscall metadata. They are not a full command transcript and do not capture file contents.

To create the persistent rule file by hand, use a quoted heredoc so the shell writes the rules literally. The reconstructed playbook writes the equivalent content to `/etc/audit/rules.d/99-project-hardening.rules`:

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

`tee` writes the root-owned file; `augenrules --check` checks whether generated rules changed; `--load` loads them into the kernel; `auditctl -l` reads the active list; `auditctl -s` reads daemon status. In the captured run, the first `auditctl -l` returned `No rules`; after creating and loading the persistent file, all nine watches appeared. The later status check showed `enabled 1`, `failure 1`, backlog limit 8192, and zero lost events. A pasted command accidentally combined `auditctl -s` twice and returned “Too many options”; running the status command alone produced the expected output.

Useful focused queries after making an authorized configuration change are:

```bash
sudo ausearch -k identity -ts today -i
sudo ausearch -k privileged-access -ts today -i
sudo ausearch -k ssh-config -ts today -i
sudo ausearch -k firewall -ts today -i
```

`-i` asks `ausearch` to interpret numeric fields into human-readable values; preserve the raw event when exact syscall data matters. Review the event's `SYSCALL`, `PATH`, `PROCTITLE`, `auid`, `uid`, `exe`, and `key` fields together. In this lab's SSM-root context, `auid=unset` meant the event did not tie itself to the human IAM caller. Correlate it with AWS SSM session/API records if attribution is required; do not claim auditd alone identified that person.

The journal recorded audit status `enabled 1`, `failure 1`, backlog limit 8192, and zero lost events at the status checks. `augenrules --check` reported `No change`, meaning the generated rules matched the source rules at that point. The configured log policy used asynchronous incremental flush, rotation at 8 MiB, five logs, and suspend actions for admin-space, disk-full, and disk-error conditions.

The audit daemon policy values recorded in `/etc/audit/auditd.conf` were:

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

These settings flush audit data incrementally, rotate at the configured file size, and define behavior when disk space becomes scarce or errors occur. On a manual reproduction, edit the existing keys with `sudoedit /etc/audit/auditd.conf` rather than blindly appending duplicate key lines. The reconstructed playbook uses `lineinfile` to update those settings. The active values and service health should be checked after the configuration handler runs.

To demonstrate that a watch rule emitted an event, the lab created and removed a harmless temporary file under `/etc/ufw`, then searched for key `firewall`:

```bash
sudo touch /etc/ufw/.audit-lab-test
sudo rm /etc/ufw/.audit-lab-test
sudo ausearch -k firewall -ts recent -i
```

Audit records contained the `touch` creation and `rm` deletion events. The recorded SSM root shell events showed `auid=unset`; therefore these records demonstrate that the filesystem events were collected but do not identify the human IAM user who initiated the SSM shell. Auditd watch coverage is also not a substitute for centralized log forwarding or a complete production audit policy.

### 7.4 Kernel and network sysctls

The initial inspection found several good kernel defaults already set, but IPv4 default and interface `send_redirects` and `accept_source_route` were still `1`. The project persisted corrections in `/etc/sysctl.d/99-linux-hardening-network.conf`, then checked the running values. This is a useful before/after example: inspect first, change only the identified weak settings, and verify the effective runtime values afterward.

The persistent project file set these values:

```text
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.ens5.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.ens5.accept_source_route = 0
```

This is the shell sequence used to write and apply those persistent network settings. It is safe to repeat as a file replacement, unlike appending with `>>`:

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

The first read showed `net.ipv4.conf.default.send_redirects=1`, `net.ipv4.conf.ens5.send_redirects=1`, and default/interface `accept_source_route=1`. After applying the file, those settings read back as `0`. This before/after check is the evidence of an effective change; a successful `tee` alone would prove only that a file was written.

It was applied and verified with:

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

To prove the values are persisted as well as currently active, inspect the file and query the running kernel separately:

```bash
sudo cat /etc/sysctl.d/99-linux-hardening-network.conf
sudo sysctl net.ipv4.conf.all.send_redirects \
  net.ipv4.conf.default.send_redirects \
  net.ipv4.conf.ens5.send_redirects \
  net.ipv4.conf.all.accept_source_route \
  net.ipv4.conf.default.accept_source_route \
  net.ipv4.conf.ens5.accept_source_route
```

The file proves the intended values were written to disk; the `sysctl` query proves the current kernel exposes the expected runtime values. Both checks matter because a correctly edited file may not have been applied, and a runtime `sysctl -w` change may disappear on reboot if no persistent configuration exists.

Recorded final values included ASLR `2`; dmesg and kernel-pointer restrictions `1`; protected hardlinks and symlinks `1`; IPv4 forwarding `0`; redirect acceptance `0`; redirect sending `0`; source routing `0`; reverse-path filtering `2`; TCP syncookies `1`; and IPv6 redirect/source-route acceptance `0`. The effective values for `all`, `default`, and `ens5` were checked separately because an `all` value alone does not guarantee an interface-specific setting is correct.

The controls address different kernel/network risks:

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

These values reduce selected attack surfaces; they do not replace security groups, UFW, patching, or workload-specific network design. `rp_filter=2` was intentionally loose mode, not strict mode. A real deployment should validate settings against its routing design, VPNs, and asymmetric paths before adopting them wholesale.

### 7.5 Logs, updates, and unit health

```bash
sudo systemctl is-active rsyslog
sudo journalctl --disk-usage
sudo journalctl -p warning --since today --no-pager
systemctl --failed --no-pager
```

`rsyslog` was active; the journal occupied 38.3 MiB at the recorded check. The warning query included EC2/virtual-hardware and CPU vulnerability notices as well as a UFW block event. These outputs should be triaged in context rather than treated as a list of confirmed exploitable issues. The final failed-unit check returned `0 loaded units listed`.

The warning review included boot-time hardware/virtualization messages, chrony clock correction, IRQ affinity warnings, and a `[UFW BLOCK]` entry. The block entry showed that the host firewall logged a packet it denied; it was not evidence that the packet reached the SFTP process. The MDS and MMIO stale-data kernel notices reported “Clear CPU buffers attempted, no microcode; SMT Host state unknown” in the guest vulnerability files. Record these as platform/runtime observations and interpret them with the cloud provider's shared-responsibility model; the guest's view cannot establish the underlying host's complete mitigation state.

The target's CPU vulnerability files reported that clearing CPU buffers had been attempted but no microcode was present and SMT host state was unknown. This was recorded as platform-level observation, not as evidence that the Linux hardening controls failed. The target was a `t3.micro` EC2 instance; its guest-visible hardware/kernel report is not equivalent to a direct assessment of the underlying AWS host.

## 8. Results and evidence

The demonstrated outcomes were:

- Both EC2 nodes had no public IP or inbound security-group rules; SSM provided administration.
- Ansible managed the private target over SSM, with temporary transfer files using the scoped S3 path.
- SFTP authenticated with a dedicated key, transferred the synthetic test file in `/upload`, and produced matching local/source SHA-256 digests.
- Chroot traversal, writes to the chroot root, and interactive-shell access were denied as intended.
- UFW was active with default-deny incoming and allow-outgoing policy; no port 22 ingress was opened.
- AppArmor, unattended-upgrades, auditd, audit watches, and the selected sysctl values were checked on the target.
- The lab's logs and failed-unit state were reviewed after the changes.

The repository's [verification record](verification.md) and [sanitized hardening evidence](../evidence/hardening-results.md) provide compact evidence tables. Preserve the distinction between actual recorded outcomes and checks that a future user must perform when rebuilding the lab. Do not include private keys, raw Terraform state, personal identifiers, AWS credentials, or unredacted account-specific resource IDs in portfolio evidence.

## 9. Destroy the infrastructure after the demonstration

After testing was complete, the learner used Terraform to tear down the lab. The first destroy attempt was blocked because the private S3 transfer bucket still contained the uploaded SFTP public-key object. Terraform cannot delete a non-empty bucket in this configuration. Remove only the lab's temporary bucket contents, then run destroy again:

```bash
aws s3 rm "s3://$(terraform -chdir=terraform output -raw ansible_transfer_bucket)" \
  --recursive --profile "$AWS_PROFILE" --region us-east-1
terraform -chdir=terraform destroy
terraform -chdir=terraform state list
```

The completed destroy reported `Destroy complete! Resources: 1 destroyed.` and `terraform state list` returned no resources. The final remaining Terraform-managed object was the S3 bucket after its contents were removed. Independent follow-up checks showed both instance IDs as `terminated`, the NAT Gateway as `deleted`, the VPC endpoint and a volume as not found, and the filtered volume query returned no volumes. A Resource Groups Tagging API query still showed old resource ARNs, which were stale tag results and did not establish that the resources were running. The contemporaneous S3 `list-buckets` check could not connect to the S3 endpoint, so independent S3 API confirmation was unavailable in that verification window.

The journal therefore records that `terraform destroy` was used after the demonstration, that Terraform state was empty afterward, and which independent service checks did and did not complete. Destroying the lab is part of the exercise: NAT Gateways and other live resources can continue to incur charges if left running.

## 10. Reproduction checklist

When repeating the exercise, use this order:

1. Confirm the AWS profile, account, Region, and target OS before changing resources.
2. Review Terraform, initialize and validate it, then inspect the complete plan.
3. Apply and wait for both instances to become SSM managed nodes.
4. Prepare the admin node, SSM Ansible connection, scoped transfer bucket, inventory, and public SFTP key.
5. Inspect the target baseline before applying host configuration.
6. Review the reconstructed Ansible playbook, syntax-check it, then apply it.
7. Prove both intended SFTP transfer and denied shell/chroot-root behavior through SSM port forwarding.
8. Verify host controls individually on the target and keep sanitized evidence.
9. Empty only the lab transfer bucket, run `terraform destroy`, and confirm Terraform state is empty.

This sequence makes the project more than a list of hardening settings: it demonstrates threat-driven design, least privilege across AWS and Linux identities, repeatable configuration, positive and negative testing, evidence collection, and cost-conscious teardown.

