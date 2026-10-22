# My Project 1B proactive Linux hardening journey

- **Core technologies:** AWS, Terraform, Systems Manager, Ansible, Ubuntu, OpenSSH/SFTP, UFW, AppArmor, auditd, and Linux sysctl.
- **Problem I addressed:** I wanted to provide a private file-transfer service without exposing SSH to the internet or giving the transfer account a shell or access to the rest of the server.
- **Outcome:** I built a private AWS lab, hardened the Ubuntu target, proved the SFTP account could transfer a file only within its upload area, checked the host controls, and used Terraform to destroy the lab when I was finished.

This is my account of Project 1B, from the choices I made before deployment to the tests I ran and the teardown afterward. I used the saved journal and captured outputs to put the steps in order. I explain what I was trying to prove as I go, because a list of commands alone does not show why the controls mattered.

I guided the lab through four connected steps. Cloud hardening is layered: AWS networking cannot replace Linux permissions, and host controls cannot make a public management path safe. I built each layer for a reason, checked how it behaved, and kept the journal so I could learn from both successful checks and the problems I had to troubleshoot.

| Step | Layer | What I worked through |
| --- | --- | --- |
| 1 | AWS infrastructure | Private network, IAM roles, encrypted storage, SSM-ready instances, and Terraform provisioning |
| 2 | Access management and SSH hardening | Separate administration from file transfer; restrict the SFTP identity, SSH behavior, and chroot filesystem boundary |
| 3 | Linux operating system hardening | Configure the host firewall, AppArmor, unattended updates, auditd, and kernel/network settings |
| 4 | Validation and cleanup | Test allowed and denied behavior, review evidence and lessons from troubleshooting, then destroy the lab |

Project 1A began with an existing server that already had unsafe settings; I investigated and remediated it. For Project 1B, I started from the other direction: I designed a small private environment, configured a Linux workload with least privilege, then tested the intended access and the boundaries around it. My transfer test used the harmless 33-byte `mds-sftp-test.txt` file. This was a controlled learning lab, not a real incident or production service.

## Why I built this lab

My goal was to build a small private AWS environment for a Linux file-transfer workload, apply least-privilege controls before using it, test both the allowed and denied behavior, and then destroy the lab.

I framed the workload as a private SFTP drop for test files. I wanted the user to transfer a file without getting a shell, browsing the host filesystem, writing outside the upload area, or connecting through public SSH. I knew a private subnet alone could not enforce all of those host-level restrictions, so I combined AWS network controls with Linux identity, OpenSSH, filesystem, firewall, audit, and kernel-network settings.

I used only the small synthetic text file shown in the transfer test. This was a learning exercise, not a production deployment.

## 1. AWS infrastructure layer — I designed and provisioned a private lab

I used my WSL workstation for Terraform and the AWS CLI. A separate EC2 admin node ran Ansible and managed the target through the AWS Systems Manager (SSM) connection plugin. I kept both EC2 instances in private subnets, with no public IPs and no inbound security-group rules. The target's local `sshd` still listened on port 22, but I reached it through SSM rather than opening SSH to the internet.

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

| Component | What I deployed or checked | Why I chose it |
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

I kept the Terraform implementation split by responsibility so I could review each part before applying it: [network.tf](../terraform/network.tf) defines the VPC, subnets, routes, and gateway; [security-groups.tf](../terraform/security-groups.tf) defines network access; [compute.tf](../terraform/compute.tf) and [ami.tf](../terraform/ami.tf) define the EC2 nodes and image; [iam.tf](../terraform/iam.tf) defines instance roles; and [s3.tf](../terraform/s3.tf) defines the private transfer bucket and endpoint-related storage settings. I used [variables.tf](../terraform/variables.tf), [terraform.tfvars.example](../terraform/terraform.tfvars.example), and [outputs.tf](../terraform/outputs.tf) for deployment inputs and useful resource outputs.

I chose one NAT Gateway instead of a NAT instance. It cost more per hour, but I did not have to add another Linux server to patch and operate. Keeping the lab to one AZ saved resources, though it is not a highly available production design. I also kept file transfer separate from administration: an SFTP key should not give its owner `sudo` or control of the operating system.

### How I routed management and data traffic

I used SSM in two distinct ways:

1. **Administration:** I asked Systems Manager to open a shell on the admin or target node. The instance SSM Agent opened outbound control and data channels, so I did not need to connect to port 22 from the internet.
2. **SFTP test:** I asked SSM to forward my local port `2222` to target port `22`. My SFTP client connected to `127.0.0.1:2222`, and the target handled an ordinary SSH/SFTP session locally.

Ansible added a third path. The controller on my admin node used SSM to run tasks on the target, while the connection plugin staged temporary module files through my private S3 bucket. The S3 Gateway endpoint routed that traffic through AWS rather than through the public internet. Each component had a different job: SSM carried management traffic, S3 staged Ansible files, and OpenSSH enforced the target's SFTP restrictions.

I treated the security group and the host firewall as separate enforcement layers. The target needed a local listener on port 22 for SFTP, but that alone did not make it reachable from an untrusted network. I kept the EC2 security group free of ingress rules and set UFW to deny incoming traffic. For this lab, I deliberately used SSM port forwarding as the authorized path.

This first layer gave me network boundaries and managed identities to build on. The private subnets kept the EC2 nodes off public addresses; security groups controlled which network paths AWS allowed; encrypted EBS protected stored blocks; and the instance roles gave each server the AWS permissions needed for its job. None of those settings, by themselves, restricted what an authenticated Linux user could do after connecting. That was why I planned a separate access layer and host-level controls.

### I confirmed my AWS identity and workstation setup

I ran these checks from my WSL project directory with the `mds-devsecops-lab` profile. If I repeat the lab in another account, I will first change to my own authorized profile and check which AWS identity it resolves to. That simple check helps me catch a wrong-account mistake before I create anything.

```bash
cd ~/mds-aws-linux-hardening-1b
aws sts get-caller-identity --profile mds-devsecops-lab
terraform version
aws --version
```

My journal notes that I used Terraform 1.16.6 and AWS CLI v2.38.3 on WSL. An early `aws --version` check returned “command not found” when run as the non-root `devsecops` user even though the CLI was available in a different shell context. I resolved it by using the ordinary `devsecops` account with its own profile and PATH. That distinction mattered: WSL was my workstation, separate from both EC2 nodes. My target was a separate Ubuntu 24.04.5 EC2 host, while WSL reported Ubuntu 26.04 on a Microsoft WSL2 kernel. I learned to check the hostname and OS before interpreting package, kernel, or firewall output.

I installed the AWS CLI under my WSL user's local directory. When a fresh shell could not find `aws`, I fixed my PATH like this:

```bash
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
aws --version
```

The first line fixed my current shell; the `.bashrc` entry made it persist in later interactive shells. My executable was `/home/devsecops/.local/bin/aws`. I made this change as `devsecops`, not root, so the CLI and its sign-in cache stayed in the same home directory.

I used AWS CLI browser sign-in to obtain temporary credentials. When that session expires, I sign in again and verify the principal and Region before provisioning:

```bash
aws login --profile mds-devsecops-lab
aws sts get-caller-identity --profile mds-devsecops-lab \
  --query Arn --output text
aws configure get region --profile mds-devsecops-lab
aws iam list-mfa-devices --user-name mds-devsecops-lab \
  --query 'length(MFADevices)' --output text
```

I confirmed that the CLI was using my named IAM lab user, the Region was `us-east-1`, and one MFA device was attached. Do not paste the full ARN/account ID, browser authorization values, password, MFA seed, QR image, or one-time codes into documentation. The lab user had broad `AdministratorAccess` during this exercise; that was a human operator permission choice, not an instance role. For a production or portfolio reproduction, prefer a role or IAM Identity Center permission set scoped to the deployment, and avoid account-wide administrator access where practical.

Before deployment, I created a dedicated IAM lab user while signed in as an already-authorized AWS administrator. These are the one-time commands I used; they are **historical lab setup commands**, not commands to run for every deployment. A managed workforce role or IAM Identity Center is preferable where available:

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

I got `1`, confirming one MFA device was attached. `SignInLocalDevelopmentAccess` let me sign in through the browser; it did not grant EC2 or S3 permissions by itself. `AdministratorAccess` gave my human lab account broad permissions in this exercise. I did not attach it to either EC2 role. I have not reproduced my MFA QR image, password, seed, or one-time codes.

### I checked the Terraform plan before deployment

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

Before I applied the plan, I checked the Region, network ranges, instance types, IAM policy scope, volume encryption, public IP settings, and security-group ingress. I wanted to catch an exposed instance or unintended permission before Terraform created anything. I found that regional EBS encryption-by-default was disabled, so I explicitly set encryption on the volumes in Terraform. I looked up the Ubuntu 24.04 AMI through Canonical's public SSM parameter, then checked its publisher, architecture, state, and image name. The image was Canonical-owned (`099720109477`), available, and `x86_64` Ubuntu Noble.

I also saved the read-only AWS preflight queries that informed my Terraform choices. These are useful before writing or applying the configuration, because CIDR overlap, unavailable instance types, an incorrect image publisher, or an assumed EBS encryption default can invalidate a plan:

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

My existing default VPC used `172.31.0.0/16`, so I chose the non-overlapping `10.20.0.0/16` range. I checked six AZs and selected `us-east-1a` for this single-AZ lab; the candidate T2/T3 sizes were available there. I also verified that Canonical owned the available `x86_64` Ubuntu image (`099720109477`). EBS encryption-by-default was `false`, and the default key was `alias/aws/ebs`. I left those account-wide settings alone and explicitly enabled encryption on the volumes Terraform created.

Cost was also part of the design decision. When I planned the lab in October 2026, my estimate was about `$32.85/month` for a continuously running NAT Gateway and `$22.85/month` for both instances, before data processing, storage, and other network charges. That could exceed my `$50` monthly budget alert. Prices change, and the alert only notifies me; it does not cap spend. I kept the cost down by running the lab only when I needed it and destroying it afterward.

```bash
terraform apply
terraform output
cd ..
```

Terraform outputs provide the admin and target instance IDs and transfer bucket name. Keep those values in the shell or an untracked local file; do not paste live identifiers into public documentation. Wait until both nodes are registered as SSM managed instances before proceeding. If a node does not appear, check its instance profile, SSM Agent status, route to the required SSM endpoints, and NAT or VPC endpoint path instead of opening inbound SSH as a shortcut.

## 2. Access management and SSH hardening — I controlled who could connect and what they could do

I chose Systems Manager Session Manager instead of opening SSH to administer either EC2 node. With public SSH, I would need an internet-reachable path and would expose a login service that I then had to protect with source restrictions, key management, patching, and monitoring. Session Manager let me start an IAM-authorized session over the SSM Agent's outbound connection, with no public IP or inbound port 22 rule. It also avoided a public bastion, which would add another server to harden and maintain. This choice still depended on correct IAM permissions, working outbound routes, and a healthy SSM Agent; it was a different controlled path, not security by itself.

I did not remove SSH from the target. The target still ran OpenSSH because SFTP is carried by SSH. I removed the public management path and used SSM to reach the local SSH service through a port-forwarding tunnel. That distinction helped me avoid treating “SSH is installed” and “SSH is exposed to the internet” as the same thing.

I kept the roles separate too: my human AWS identity provisioned the lab, each instance role let its agent communicate with SSM, and the admin node's controller role handled its scoped SSM and S3 transfer work. This separation limited what I had to grant to each component.

### I connected to the admin node with Session Manager

From the workstation, start a session to the admin node:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw admin_instance_id)" \
  --profile "$AWS_PROFILE" --region us-east-1
```

An SSM session is initiated through AWS APIs and the SSM Agent's outbound channels. The instance does not need a public address or an inbound SSH rule. On the admin node, install Ansible, the Session Manager plugin, and the collections listed in `ansible/requirements.yml`. Check the SSM connection plugin's documented requirements and confirm the target is online before running Ansible.

The controller uses `amazon.aws.aws_ssm`. Its module transfers use the configured private S3 bucket, so the admin role needs bucket-scoped transfer permissions and the target must be able to reach S3 using the configured path. The target agent role has only the five selected SSM channel actions; the admin controller's session and bucket permissions are separate. Do not replace these roles with `AdministratorAccess` to make a connection problem disappear.

I reviewed `AmazonSSMManagedInstanceCore` before choosing a narrower instance policy. It included parameter, patching, inventory, and compliance actions this lab did not need, so I used a five-action Session Manager policy for the instance agent:

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

I kept this **instance-agent** policy separate from both my human AWS permissions and the Ansible controller policy. The controller also needed permission to start and end a target session, plus access to the transfer bucket. I scoped its S3 actions (`GetObject`, `PutObject`, `ListBucket`, `DeleteObject`, and `GetBucketLocation`) to the lab bucket and its objects. I did not attach my human administrator policy to either EC2 role.

### I prepared Ansible and the SFTP key

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

I wrote down this key-staging sequence so I could repeat it. I ran the first two commands on my workstation and the download on the admin node, replacing `YOUR_TRANSFER_BUCKET` with Terraform's output. I uploaded only the public key; the private key stayed on my workstation.

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

`ssh-keygen` prompts for a passphrase; I never record or share it. In my run, the target account had UID/GID 1002. In a reusable playbook, I prefer referring to `sftpdata` and `sftp-only` by name instead of hard-coding those numbers.

I had to troubleshoot the Ansible-over-SSM path because a working SSM shell did not guarantee that Ansible could stage its temporary files through S3. I checked the plugin and collection, bucket name and permissions, target access to S3, and the controller role before considering any network change. My original run finished with `ok=17`, `changed=3`, `unreachable=0`, and `failed=0`.

### I inspected the target before changing access policy

I opened a second SSM session directly to the target so I could inspect it before hardening and return to it for final checks:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw target_instance_id)" \
  --profile "$AWS_PROFILE" --region us-east-1
```

Unless I say otherwise, I ran the commands in this section **inside the target's SSM shell**. I captured the hostname, OS release, kernel, package state, services, listeners, and current control state first. That way, I knew I was looking at the target rather than confusing it with my WSL workstation or the admin node.

```bash
hostname
cat /etc/os-release
uname -r
systemctl list-units --type=service --state=running --no-pager
ss -lntup
```

My target was Ubuntu 24.04.5 LTS on an AWS kernel. I found SSH listening on IPv4 and IPv6 wildcard addresses, along with local DNS resolver sockets and chrony. That did not make SSH publicly reachable: the instance had no public IP and its security group had no inbound rules. I planned to test SFTP through SSM port forwarding.

Before I hardened the host, UFW was inactive and the firewall chains showed default ACCEPT policies. AppArmor was already enabled and active, with 122 profiles loaded and 26 enforcing. I also confirmed unattended-upgrades was active and enabled after I reran a malformed combined command correctly. Separating the commands helped me avoid misattributing output to the wrong host.

To inspect patch state and reboot requirements:

```bash
apt list --upgradable 2>/dev/null
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required
else
  echo "No reboot is currently required"
fi
```

When I checked updates, four packages were available but deferred by Ubuntu's phased rollout: `cloud-init`, `tmux`, `ubuntu-pro-client`, and `ubuntu-pro-client-l10n`. I left the rollout intact rather than forcing them. No reboot was required at that check. I also learned that an enabled unattended-upgrades service does not mean every package installs immediately, so I checked its log and allowed origins.

### I prepared the target's separate data volume

I prepared this disk before running Ansible. The playbook checks that `/srv/sftp-data` is already mounted and stops if it is not. I recorded that the disk ended up formatted as ext4 and mounted persistently by UUID with `defaults,nofail`, but I did not preserve the exact original format-and-mount command transcript. The commands below show how I would safely repeat that one-time step on a **new, empty lab volume only**.

First identify the attached 5-GiB volume and confirm it is not mounted and has no filesystem/data that needs to be preserved:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS
sudo blkid
```

My device appeared as `/dev/nvme1n1`; numbering can differ, so I verify the disk rather than copying that name blindly. Only after confirming the intended volume is blank would I create the filesystem and mount point:

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

I expected filesystem type `ext4`, mount point `/srv/sftp-data`, and the new volume's UUID as the source. I would never rerun `mkfs` on an existing filesystem. The Ansible playbook does **not** format a disk, write `/etc/fstab`, or mount it; it checks the mount and stops if I have not prepared it. Keeping disk initialization separate from routine hardening means an Ansible rerun cannot erase the data volume.

### I applied SSH and account restrictions with Ansible

I used [harden-target.yml](../ansible/playbooks/harden-target.yml) to apply the account, SSH, filesystem, and host-control settings. I reviewed its variables and handlers before applying it to the target.

In the recorded lab, Ansible applied several target settings in one hardening run. I explain the SSH and account boundary here, then group UFW, AppArmor, auditd, unattended upgrades, and sysctl under the Linux operating-system layer in Step 3. That organization makes the purpose of each layer easier to follow; it does not imply I deployed a separate playbook for each one.

On the admin node, install the declared collections and run the syntax check, then apply against the target inventory:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml --syntax-check
ansible-playbook -i ansible/inventory/hosts.yml \
  ansible/playbooks/harden-target.yml
```

I wanted the target to have the following controls in place:

1. **Separate SFTP identity:** user `sftpdata`, group `sftp-only`, UID/GID 1002 in the recorded run, locked password, and `/usr/sbin/nologin` shell.
2. **Chrooted OpenSSH:** the `sftpdata` match block uses the internal SFTP subsystem, disables forwarding and interactive shell capability, and confines the account to `/srv/sftp-data`.
3. **Dedicated data filesystem:** the separate encrypted 5-GiB gp3 EBS device was formatted as ext4, mounted by UUID at `/srv/sftp-data` with `defaults,nofail`, and used independently of the root filesystem.
4. **Safe chroot ownership:** `/srv/sftp-data` remained `root:root` mode `0755`, as required by OpenSSH; `/srv/sftp-data/upload` was `sftpdata:sftp-only` mode `0750` and was the only writable transfer location.
5. **Key-only access:** `/home/sftpdata/.ssh` was mode `0700`; `authorized_keys` was owned by the transfer identity and mode `0600`. Password login was disabled for this SFTP identity.
6. **Firewall and host controls:** UFW was configured with deny incoming, allow outgoing, IPv6 enabled, and low logging. AppArmor and unattended-upgrades service state was checked. Auditd policy and rules, plus persistent kernel/network sysctls, were installed.

### I restricted SSH to SFTP for the transfer account

I configured an SSH drop-in at `/etc/ssh/sshd_config.d/00-project-hardening.conf` with this policy:

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

Before installing an SSH change, I validate the candidate file and then check the effective settings for the SFTP user. The playbook uses `sshd -t` to reject invalid syntax before replacing the file. I use this sequence for a manual review:

```bash
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1 \
  | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|forcecommand|chrootdirectory|allowtcpforwarding|permittty)'
```

`sshd -t` checks syntax. `sshd -T -C` evaluates the effective settings for a connection context, including `Match` rules; it is stronger evidence than reading a file in isolation. During the lab, the first effective-config query was blocked because `/run/sshd` was missing. Creating that runtime directory allowed the check to proceed. If the command fails on another system, inspect its exact error and service/runtime state before changing authentication policy.

Before formatting, I identified the attached data disk; formatting an unverified device could erase the wrong data. When I repeat the lab, I check the size, filesystem, and mount state first. I also review the playbook for idempotence and SSH syntax validation (`sshd -t`). I do not add inbound UFW or security-group access to TCP 22 because SSM is my management and test path.

### I checked the mount, account, permissions, and effective SSH policy

After Ansible completed, I ran these read-only checks in the target's SSM shell to make sure the filesystem and account matched the policy I intended:

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

`lsblk -f` identifies block devices, filesystem type, and UUID; `findmnt` confirms the dedicated filesystem is mounted at the expected chroot path. The expected account has the restricted group, `nologin` shell, and no administrative group membership. `namei -l` walks every parent directory and exposes an unsafe owner or mode in the path, while `stat` checks the final objects. I verified the chroot as `root:root 755`, the upload directory as `sftpdata:sftp-only 750`, `.ssh` as `sftpdata:sftp-only 700`, and `authorized_keys` as `sftpdata:sftp-only 600`.

The effective SSH settings should be tested for the restricted account, not inferred from the global file alone:

```bash
sudo install -d -o root -g root -m 0755 /run/sshd
sudo sshd -t
sudo sshd -T -C user=sftpdata,host=localhost,addr=127.0.0.1 \
  | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|forcecommand|chrootdirectory|allowtcpforwarding|permittty)'
```

I added the `install -d` check because `/run/sshd` was missing during my first manual `sshd -T` check. Creating it restored the runtime directory; it did not change the persistent SSH policy. On a system where the service manager has already created it, this step is unnecessary. I used `sshd -T -C` to inspect the effective `Match` policy for `sftpdata`, rather than relying only on the text of the drop-in.

### I tested SFTP access and the boundaries around it

### I opened the SSM port-forwarding tunnel

From the workstation, open a port-forwarding session to the target's local SSH service. Leave this terminal open while testing from another terminal.

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw target_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}' \
  --profile "$AWS_PROFILE" --region us-east-1
```

This maps workstation `127.0.0.1:2222` through SSM to target port 22. It does not create an inbound network rule. The tunneled SSH/SFTP payload is encrypted; SSM session start/stop records do not expose tunneled filenames or file contents.

### I verified the server identity and transferred a test file

In another workstation terminal, connect with the dedicated private key:

```bash
sftp -P 2222 -i ~/.ssh/mds-linux-hardening-1b-sftpdata \
  -o IdentitiesOnly=yes sftpdata@127.0.0.1
```

The SSH host key shown through the local tunnel should be verified against the target's public host-key fingerprint, obtained through the trusted SSM administration channel. I compared the ED25519 fingerprint in my workstation's `[127.0.0.1]:2222` known-host entry with the target's `/etc/ssh/ssh_host_ed25519_key.pub`; they matched. This checks that the tunnel terminates at the expected target instead of silently trusting an unknown host key.

The comparison commands used were:

```bash
# Workstation: fingerprint of the host key learned through the local SSM tunnel.
ssh-keygen -F '[127.0.0.1]:2222' | ssh-keygen -lf - -E sha256

# Target SSM shell: fingerprint of the target's actual ED25519 public host key.
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Compare the `SHA256:` fingerprint strings. The host key is distinct from the SFTP user's client key: the client private key proves the user's identity to the server; the server host key lets the client verify which server it reached.

My SFTP session opened at `/upload`. The test created a harmless local file, uploaded it to `/upload`, downloaded it to a different local path, and compared SHA-256 digests. From the SFTP prompt, `!` runs a local workstation command (it does not run a command on the target):

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

### What I learned while troubleshooting

I ran into a few issues that are worth remembering:

- `ssh -T` returning “This service allows sftp connections only” was the expected denied-shell result, not a failed SFTP configuration.
- Uploading to `/` returned `Permission denied` by design. Use `/upload` for transfers; do not loosen chroot-root ownership to make the root writable.
- Host-key fingerprints should be compared through the SSM management channel. Do not disable host-key checking as a routine fix.
- A successful SSM shell does not by itself prove that the Ansible SSM plugin can stage its temporary S3 files. Check plugin prerequisites and bucket permissions separately.
- `sshd -T` initially could not run because `/run/sshd` did not exist. The runtime directory was created, after which the effective configuration could be checked. This is an ephemeral runtime prerequisite, not a reason to edit SSH policy blindly.
- Some transcript output was accidentally concatenated (for example, `systemctl` checks, UFW status, and command text without separators). Re-run one command at a time and confirm the hostname before recording conclusions.

## 3. Linux operating system hardening — I added host-level defense in depth

The AWS layer controlled network reachability; here I hardened the system that receives a permitted connection. I enabled a host firewall for a second network decision point, checked AppArmor and automatic security updates, installed auditd to leave evidence of sensitive configuration changes, and persisted kernel/network settings that reduce selected attack surfaces. I verified each control on the target through SSM so I would not mistake WSL or the admin node for the host I meant to secure.

I added auditd because access controls tell me what should be allowed, while audit records help me review whether watched security-sensitive files were changed. I added the sysctl settings because secure network placement does not change kernel behavior such as forwarding, redirects, or source routing. I checked unattended upgrades because a hardened server still needs a safe way to receive security fixes. For AppArmor, I checked the actual loaded and enforcing profiles instead of assuming that an enabled service meant every process had a tailored profile.

Ansible represented this work as one repeatable run, but the controls protect different things. The SSH policy and SFTP filesystem boundary limit the transfer identity; UFW filters at the host; AppArmor confines supported processes; auditd records watched changes; sysctl configures kernel behavior. I treated these as layers that complement each other, not as interchangeable checklist items.

Run these checks in the **target's SSM shell**, not the workstation or admin node. Capture sanitized output and avoid publishing account IDs, internal addresses, access keys, or private key material.

### I checked AppArmor and unattended upgrades

```bash
sudo aa-status
systemctl is-enabled apparmor
systemctl is-active apparmor
systemctl is-enabled unattended-upgrades
systemctl is-active unattended-upgrades
sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
```

I confirmed AppArmor was enabled and active. It had 122 profiles loaded, with 26 enforcing; `chronyd` and `rsyslogd` were among them. The SSM Agent profile was in complain mode. I treated `aa-status` as evidence of the profile states it listed, not proof that every workload had a tailored enforcing profile.

I confirmed unattended-upgrades was enabled and active. Its log listed the allowed Ubuntu Noble update and security origins, but no packages were ready to install at that check. My package list separately showed four phased updates, and I left Ubuntu's rollout behavior alone.

### I checked the firewall and network listeners

```bash
sudo ufw status verbose
sudo ufw status numbered
sudo ss -lntup
sudo iptables -S
sudo ip6tables -S
```

After I enabled UFW, I confirmed it was active with low logging, default deny incoming, allow outgoing, and routed traffic disabled. IPv6 support was enabled in UFW configuration. No explicit inbound SSH allow rule was added. The systemd socket/listener inventory still showed local SSH on port 22, but the EC2 security groups had no inbound rules. A process listening on an interface and a port reachable from the Internet are different facts; check both host and cloud network controls.

I deliberately did not add an SSH exception. My rule was simple: deny unsolicited inbound traffic at the host, and use SSM for administration and the SFTP test. I left outbound traffic allowed for expected updates and management. Seeing UFW report `active` confirmed that its policy was enabled, but I still checked the cloud security group separately. The earlier `iptables -S` output with ACCEPT policies was from before UFW was enabled, so I did not treat it as the final firewall result. I relied on both the final UFW status and successful SSM/SFTP tests.

My first `ufw status numbered` attempt returned usage text because I had accidentally joined it to `IPV6=yes`. I ran it separately and got the status output. The earlier `ufw: command not found` result belonged to the WSL host, where UFW was not installed; it was not evidence about the AWS target. This is why host identity and clean command boundaries matter in a multi-node lab.

I also kept the manual commands I used to set the firewall policy on the target. In the playbook, I express the same intent declaratively:

```bash
sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose
```

`--force` avoids an interactive confirmation, which is useful for automation; use it only after verifying a recovery path. SSM was already working and did not depend on inbound SSH. The sequence intentionally does not add `ufw allow 22/tcp`. If a future deployment manages the host only over SSH, enabling deny-incoming without a verified alternate management path can lock out the operator. The recorded project enabled UFW and then confirmed that new SSM and tunneled SFTP sessions still worked.

### I installed and tested auditd

Auditd was not installed at the initial package check. Installing `auditd` and `audispd-plugins` created the service unit. The first `systemctl enable --now auditd` attempt failed because the package installation had not completed yet. After installation completed, the command succeeded and both `systemctl is-enabled auditd` and `systemctl is-active auditd` returned `enabled` and `active`.

The corrected manual package/service order is:

```bash
sudo apt-get update
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd
systemctl is-enabled auditd
systemctl is-active auditd
```

I learned to wait for package installation to finish before enabling the service. My first attempt came too early, before `auditd.service` existed. Once the packages had installed and created the unit, enabling and starting auditd succeeded.

Check the audit daemon and loaded rules:

```bash
sudo auditctl -s
sudo augenrules --check
sudo auditctl -l
```

I loaded watches for changes to account files, privilege configuration, SSH configuration, and UFW:

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

To create the persistent rule file by hand, use a quoted heredoc so the shell writes the rules literally. The playbook writes the equivalent content to `/etc/audit/rules.d/99-project-hardening.rules`:

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

My later `auditctl -s` check showed `enabled 1`, `failure 1`, backlog limit 8192, and zero lost events. `augenrules --check` returned `No change`, so the generated rules matched the source rules at that point. I also set the log policy to flush incrementally, rotate at 8 MiB with five logs, and suspend on admin-space, disk-full, and disk-error conditions.

I set the following audit daemon policy values in `/etc/audit/auditd.conf`:

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

These settings flush audit data incrementally, rotate at the configured file size, and define behavior when disk space becomes scarce or errors occur. On a manual reproduction, edit the existing keys with `sudoedit /etc/audit/auditd.conf` rather than blindly appending duplicate key lines. The playbook uses `lineinfile` to update those settings. The active values and service health should be checked after the configuration handler runs.

To test a watch rule, I created and removed a harmless temporary file under `/etc/ufw`, then searched for the `firewall` key:

```bash
sudo touch /etc/ufw/.audit-lab-test
sudo rm /etc/ufw/.audit-lab-test
sudo ausearch -k firewall -ts recent -i
```

I found both the `touch` creation and `rm` deletion in the audit records. Because I ran the SSM shell as root, the events showed `auid=unset`; auditd proved the filesystem events were collected, but it did not identify which human IAM user opened the SSM session. I would correlate those events with SSM session/API records if attribution were required. These watches also do not replace centralized logging or a complete production audit policy.

### I hardened and verified kernel and network settings

When I inspected the kernel settings, several defaults were already strong, but IPv4 default and interface `send_redirects` and `accept_source_route` were still `1`. I recorded those values, wrote the corrections to `/etc/sysctl.d/99-linux-hardening-network.conf`, applied the file, and checked the live values again.

The persistent project file set these values:

```text
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.ens5.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.ens5.accept_source_route = 0
```

I wrote and applied those network settings with this shell sequence. It replaces the file each time, so I could repeat it without appending duplicate entries:

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

The first read showed `net.ipv4.conf.default.send_redirects=1`, `net.ipv4.conf.ens5.send_redirects=1`, and default/interface `accept_source_route=1`. After I applied the file, those settings read back as `0`. Comparing before and after showed the kernel was using the new values; a successful `tee` alone would only show that I wrote a file.

I applied the file and checked the live settings with:

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

The file check showed what would persist across a restart; the `sysctl` query showed what the kernel was using at that moment. I wanted both because a correct file might never have been applied, while a one-time runtime change could disappear after reboot.

When I verified the final values, I saw ASLR `2`; dmesg and kernel-pointer restrictions `1`; protected hardlinks and symlinks `1`; IPv4 forwarding `0`; redirect acceptance `0`; redirect sending `0`; source routing `0`; reverse-path filtering `2`; TCP syncookies `1`; and IPv6 redirect/source-route acceptance `0`. The effective values for `all`, `default`, and `ens5` were checked separately because an `all` value alone does not guarantee an interface-specific setting is correct.

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

### I reviewed logs, pending updates, and failed services

```bash
sudo systemctl is-active rsyslog
sudo journalctl --disk-usage
sudo journalctl -p warning --since today --no-pager
systemctl --failed --no-pager
```

I confirmed `rsyslog` was active and the journal used 38.3 MiB at the time I checked it. My warning query showed EC2/virtual-hardware and CPU notices, along with a UFW block event. I reviewed them in context instead of treating every warning as a confirmed vulnerability. My final failed-unit check returned `0 loaded units listed`.

I saw boot-time hardware/virtualization messages, a chrony clock correction, IRQ-affinity warnings, and a `[UFW BLOCK]` entry. That block showed UFW logged a denied packet; it did not show that the packet reached SFTP. The guest vulnerability files also reported “Clear CPU buffers attempted, no microcode; SMT Host state unknown” for MDS and MMIO stale data. I recorded those as platform observations. A guest-visible report cannot tell me the complete mitigation state of the underlying AWS host.

My target's vulnerability files reported that the kernel had attempted to clear CPU buffers, but no microcode was present and the SMT host state was unknown. I treated this as a platform-level observation, not proof that my Linux hardening failed. The target was a `t3.micro`; its guest view is not a direct assessment of the underlying AWS host.

## 4. Validation and cleanup — I checked the result and closed the lab

The fourth step brought the evidence together. I had tested the SFTP path while working through the access layer, then checked the host controls and logs here. The journal was useful because it preserved the context around mistakes and misleading outputs; those are part of how I learned to validate the system rather than simply rerunning commands until they looked right.

### What I learned from the journal

I kept the journal so the small failures and confusing moments would not disappear behind the final “it works” result. They helped me understand what each layer depended on and what a useful verification actually looked like:

| What happened | What I learned and how I responded |
| --- | --- |
| AWS CLI was missing from one WSL shell, and at first I was mixing up the workstation, admin node, and target. | I fixed the `devsecops` user's PATH and checked the hostname, OS, profile, and AWS identity before interpreting results. A command's output is only useful when I know which machine and identity produced it. |
| An SSM shell worked, but Ansible still had trouble transferring its temporary modules. | SSM connectivity alone did not prove the Ansible connection path was ready. I checked the plugin and collection, controller permissions, bucket name and permissions, and target's S3 route separately. |
| SFTP rejected shell access and denied an upload to `/`. | Those were successful negative tests: the account was for file transfer only, and the chroot root was intentionally not writable. I used `/upload` for transfers and kept the root-owned chroot boundary intact. |
| My first auditd enable attempt said the service unit did not exist. | The package installation had not finished when I tried to enable it. I waited for `auditd` and `audispd-plugins` to install, then enabled and verified the service and loaded rules. |
| UFW printed usage text after I accidentally joined a command with `IPV6=yes`; another `ufw: command not found` came from WSL. | I reran the check as a clean, separate command on the target. The error was a reminder to verify the host before diagnosing a firewall. |
| Terraform could not delete the S3 bucket while the public-key object was still in it. | I removed the temporary contents of the lab bucket and ran `terraform destroy` again. I then checked Terraform state and the AWS service states; I treated stale tag results and an unavailable S3 API check as limited evidence, not proof the resources were still running. |

Some of these details already appear beside the relevant commands above; I bring them together here because that is exactly why I kept the journal. It lets me explain not only what I changed, but what I initially misunderstood, how I corrected it, and what evidence finally answered the question.

### I reviewed what the tests proved

By the end of the lab, I had confirmed that:

- Both EC2 nodes had no public IP or inbound security-group rules; SSM provided administration.
- Ansible managed the private target over SSM, with temporary transfer files using the scoped S3 path.
- SFTP authenticated with a dedicated key, transferred `mds-sftp-test.txt` in `/upload`, and produced matching local/source SHA-256 digests.
- Chroot traversal, writes to the chroot root, and interactive-shell access were denied as intended.
- UFW was active with default-deny incoming and allow-outgoing policy; no port 22 ingress was opened.
- AppArmor, unattended-upgrades, auditd, audit watches, and the selected sysctl values were checked on the target.
- I reviewed the logs and checked for failed units after making the changes.

I collected the concise results in the [verification record](verification.md) and [sanitized hardening evidence](../evidence/hardening-results.md). When I publish evidence, I keep actual results separate from checks a future rebuild still needs to perform, and leave out private keys, raw Terraform state, personal identifiers, AWS credentials, and account-specific resource IDs.

### I destroyed the AWS lab when I was done

Once I had finished the tests, I used Terraform to tear down the lab. My first destroy attempt stopped because the private S3 transfer bucket still held the uploaded SFTP public key. Terraform could not delete a non-empty bucket, so I emptied the lab bucket and ran destroy again:

```bash
aws s3 rm "s3://$(terraform -chdir=terraform output -raw ansible_transfer_bucket)" \
  --recursive --profile "$AWS_PROFILE" --region us-east-1
terraform -chdir=terraform destroy
terraform -chdir=terraform state list
```

Terraform reported `Destroy complete! Resources: 1 destroyed.`, and my state list was empty. The S3 bucket was the final Terraform-managed resource; an earlier destroy had been blocked while it still contained the SFTP public key. After I emptied it, the final destroy completed. I then checked the EC2 services: both instances were `terminated`, the NAT Gateway was `deleted`, and the endpoint and queried volume were not found. A filtered volume query returned no volumes. The tagging API still showed old ARNs, but those stale tag results did not mean the resources were running. My S3 `list-buckets` check could not reach the S3 endpoint at that time, so I could not use it as independent confirmation.

I recorded the destroy result and the independent checks I could complete afterward. Destroying the lab was part of the exercise: a NAT Gateway and other live resources can continue to cost money if I leave them running.

### How I would repeat the four-step lab

If I build the lab again, I will follow the same four steps:

1. **Build the AWS foundation:** confirm my identity and Region, review the Terraform plan, deploy the private network and encrypted resources, and wait for both nodes to register with SSM.
2. **Control access:** connect through SSM, configure the distinct instance/controller permissions, prepare the SFTP public key and separate chroot filesystem, then apply and verify the restricted account and SSH policy.
3. **Harden Ubuntu:** configure UFW and the host controls, load audit rules, and verify persistent and live kernel settings.
4. **Prove and close:** test a successful transfer and expected denials, review logs and service state, preserve sanitized evidence, empty only the lab bucket, run `terraform destroy`, and check that Terraform state is empty.

What I took from the project was the value of proving both sides of a security control: the legitimate user could complete the transfer, and the same identity could not cross the boundaries I had set. I also saw how AWS access, Linux permissions, audit evidence, and cost management fit together in a small but realistic exercise.

