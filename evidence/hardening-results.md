# Sanitized lab evidence

## Ansible and SFTP

- Ansible target configuration recap: `ok=17 changed=3 unreachable=0 failed=0`.
- Dedicated SFTP key fingerprint matched the staged public key.
- SFTP access through an SSM port-forward succeeded after stopping and starting the instances.
- Initial SFTP virtual directory: `/upload`.
- Moving above the chroot root stayed at `/`; the target's real `/etc` was unavailable.
- Upload and download in `/upload` succeeded and the SHA-256 hashes matched.
- Upload to the chroot root returned `Permission denied`.
- Remote shell attempt returned `This service allows sftp connections only.`
- A second SFTP check after enabling UFW also succeeded.

## Host controls

- UFW: active, enabled at startup, default deny incoming, allow outgoing, low logging, IPv6 enabled.
- AppArmor: loaded; 122 profiles reported, with 26 enforcing at the recorded check. The SSM Agent profile was in complain mode.
- Unattended upgrades: service enabled and active; no reboot was required at the time checked.
- Auditd: enabled and active; nine persistent watches loaded for identity, privileged access, SSH configuration, and firewall configuration.
- Audit test: creation and removal of a harmless file in `/etc/ufw` were captured under the `firewall` key.
- Sysctl: selected ASLR, pointer exposure, redirect/source-route, forwarding, reverse-path-filter, and SYN-cookie settings were read back and matched the intended baseline.
- Service health: `systemctl --failed --no-pager` returned `0 loaded units listed`.

## Teardown

- Final Terraform destroy reported `Destroy complete! Resources: 1 destroyed.`
- `terraform state list` returned no resources.
- Follow-up AWS service checks showed both instances terminated and the NAT Gateway deleted. Some old tagged ARNs remained in the tagging API response; they were not evidence of running instances.
- Independent S3 list verification could not be completed during the endpoint connectivity error.

No customer data, private keys, AWS credentials, account IDs, instance IDs, public IP addresses, or Terraform state are included in this evidence file.
