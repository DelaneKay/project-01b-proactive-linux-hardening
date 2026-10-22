# Project 1B — Step-by-step lab walkthrough

This walkthrough records the lab that was performed and gives a repeatable path for rebuilding it. The AWS resources from the recorded run have been destroyed. The Terraform files are the source used for that deployment; the Ansible playbook in this repository was reconstructed from the verified final configuration because the temporary original playbook was not saved.

## 1. Goal and threat being addressed

The target was a private Ubuntu 24.04 server for synthetic file transfers. The security goal was to allow one dedicated account to upload and download files while preventing general shell access, chroot escape, writes outside the upload area, or public SSH exposure.

The risk was broader than an open internet port: even with no inbound security-group rules, a running SSH daemon could provide excessive capability to a user who authenticated through an allowed path. The controls therefore combined AWS network boundaries with Linux account, SSH, filesystem, firewall, and audit settings.

## 2. Provision the private lab

The Terraform configuration creates:

- one VPC and a public subnet for the NAT Gateway;
- private subnets for the admin and target nodes;
- two Ubuntu EC2 instances without public IPs and with no inbound security-group rules;
- IMDSv2-required instance metadata options;
- minimal Session Manager instance roles and a scoped Ansible controller policy;
- an encrypted root volume on each node and a separate encrypted data volume on the target;
- a private, encrypted, lifecycle-managed S3 bucket for temporary Ansible transfers and an S3 Gateway endpoint.

Use a dedicated non-root AWS identity. From the project `terraform/` directory:

```bash
cp terraform.tfvars.example terraform.tfvars
export AWS_PROFILE=your-lab-profile
aws sts get-caller-identity
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply
terraform output
```

Review the plan for the expected region and small lab instance types before applying. The single-AZ NAT design incurs charges while running. Save the `target_instance_id`, `admin_instance_id`, and `ansible_transfer_bucket` outputs for the next steps; do not write account-specific output values into tracked files.

## 3. Establish SSM management access

Start a Session Manager shell to the admin node from the workstation:

```bash
aws ssm start-session --target "$(terraform -chdir=terraform output -raw admin_instance_id)" \
  --profile "$AWS_PROFILE" --region us-east-1
```

On the admin node, install Ansible, the Session Manager plugin, and collections listed in `ansible/requirements.yml`. Check that the target is registered as an SSM managed node before attempting Ansible. The admin instance role provides the controller's target-session and temporary S3-transfer permissions; the target role provides the agent's Session Manager channel permissions.

The Ansible inventory uses `amazon.aws.aws_ssm` and the S3 bucket output. Copy `ansible/inventory/hosts.example.yml` to `ansible/inventory/hosts.yml` on the controller, replace the target instance ID and bucket name, and keep the inventory file out of version control if it contains account-specific values.

## 4. Prepare a dedicated SFTP key and data volume

Generate a dedicated Ed25519 key pair on the workstation. Keep the private key outside the repository. Upload only the public key to the private transfer bucket and retrieve it on the admin node to the path configured as `sftp_public_key_file` in inventory.

The target's separate 5 GiB gp3 EBS volume was formatted as ext4 and mounted persistently at `/srv/sftp-data` using its filesystem UUID and `nofail`. Confirm the attached data volume and mount path before applying account permissions; never format a device until verifying that it is the intended empty lab volume.

Expected directory ownership:

| Path | Owner and group | Mode | Purpose |
| --- | --- | --- | --- |
| `/srv/sftp-data` | `root:root` | `0755` | OpenSSH chroot root; not writable by SFTP account |
| `/srv/sftp-data/upload` | `sftpdata:sftp-only` | `0750` | Transfer-only writable directory |
| `/home/sftpdata/.ssh` | `sftpdata:sftp-only` | `0700` | SFTP authorized key directory |
| `/home/sftpdata/.ssh/authorized_keys` | `sftpdata:sftp-only` | `0600` | Dedicated public key |

## 5. Apply target hardening

The reusable playbook is `ansible/playbooks/harden-target.yml`. It applies the dedicated user/group, authorized key, SSH restrictions, UFW policy, AppArmor and unattended-upgrades service state, auditd configuration and watch rules, and persistent sysctl settings.

On the admin node:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/harden-target.yml --syntax-check
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/harden-target.yml
```

SSH configuration is validated with `sshd -t` before installation. No inbound UFW or security-group allow rule for TCP 22 is added. Management continues over SSM; SFTP is tested through an SSM port-forwarding session.

## 6. Test both allowed and denied behavior

From a workstation terminal, open the SSM port-forwarding session:

```bash
aws ssm start-session \
  --target "$(terraform -chdir=terraform output -raw target_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["22"],"localPortNumber":["2222"]}' \
  --profile "$AWS_PROFILE" --region us-east-1
```

In a second terminal, use the dedicated private key to connect with SFTP:

```bash
sftp -P 2222 -i ~/.ssh/project-1b-sftpdata sftpdata@127.0.0.1
```

Confirm that the initial location is `/upload`; `pwd` should show the SFTP virtual path. Upload a harmless test file into `/upload`, download it to a different local path, then compare hashes:

```bash
sha256sum /tmp/sftp-test.txt /tmp/sftp-test-downloaded.txt
```

The observed hashes matched. Also verify the denied paths: moving above the chroot stayed at `/`, the target's real `/etc` was unavailable, uploading to the chroot root returned `Permission denied`, and attempting a remote shell command returned `This service allows sftp connections only.`

## 7. Verify host controls through SSM

Open a Session Manager shell to the target and capture sanitized output for:

```bash
sudo ufw status verbose
sudo aa-status
systemctl is-enabled apparmor unattended-upgrades auditd
systemctl is-active apparmor unattended-upgrades auditd rsyslog
sudo auditctl -l
sudo augenrules --check
sudo sysctl kernel.randomize_va_space kernel.dmesg_restrict kernel.kptr_restrict \
  fs.protected_hardlinks fs.protected_symlinks net.ipv4.ip_forward \
  net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects \
  net.ipv4.conf.ens5.send_redirects net.ipv4.conf.all.accept_source_route \
  net.ipv4.conf.default.accept_source_route net.ipv4.conf.ens5.accept_source_route \
  net.ipv4.conf.all.rp_filter net.ipv4.conf.ens5.rp_filter \
  net.ipv4.tcp_syncookies net.ipv6.conf.all.accept_redirects \
  net.ipv6.conf.all.accept_source_route
systemctl --failed --no-pager
```

For the audit test, create and remove a harmless temporary file under `/etc/ufw`, then search the `firewall` key. Do not change real firewall policy files merely to generate evidence. The recorded audit test captured both creation and deletion. Audit records from the SSM root shell had `auid=unset`, so those events did not identify the initiating IAM user.

## 8. Tear down the lab

The private S3 bucket must be empty before Terraform can delete it. Remove only temporary lab objects, then destroy the stack:

```bash
aws s3 rm "s3://$(terraform -chdir=terraform output -raw ansible_transfer_bucket)" \
  --recursive --profile "$AWS_PROFILE" --region us-east-1
terraform -chdir=terraform destroy
terraform -chdir=terraform state list
```

The recorded destroy completed; Terraform state was empty afterward. Direct EC2 checks showed both instances terminated and the NAT Gateway deleted. A stale tag query still showed some old ARNs, so service-specific state checks were used instead. The S3 list check could not connect during that verification window.

## Recorded result

The demonstrated target was reachable through SSM, while direct inbound SSH remained closed. The SFTP account could transfer files only in its chroot upload directory. UFW, AppArmor, unattended-upgrades, auditd, and the selected persistent kernel/network controls were active or loaded and checked. The infrastructure was destroyed after the demonstration.
