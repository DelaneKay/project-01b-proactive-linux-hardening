# Verification record

This record summarizes observed results supplied during the completed lab. It separates those results from the reconstructed Ansible playbook, which is included for repeatability but was not the exact saved file used in the original run.

| Control | Test | Observed result |
| --- | --- | --- |
| SSM administration | Start a new Session Manager shell after UFW was enabled | Succeeded; target hostname was returned |
| Security-group boundary | Inspect target security-group ingress | No inbound rules; TCP 22 was not exposed through the security group |
| SFTP-only identity | Attempt an SSH shell as `sftpdata` | Denied with `This service allows sftp connections only.` |
| Chroot confinement | Change to parent and attempt access to the real `/etc` | Session remained at `/`; target `/etc` was unavailable |
| Chroot write boundary | Upload a file to the chroot root | Denied with `Permission denied` |
| Allowed transfer | Upload and download a harmless test file under `/upload` over SSM port forwarding | Succeeded; SHA-256 hashes matched |
| SSH host identity | Compare ED25519 host-key fingerprint over SSM with the workstation's known-host entry | Fingerprints matched |
| Firewall | `ufw status verbose` and a new SSM connection | Active; deny incoming, allow outgoing; SSM still succeeded |
| AppArmor | `systemctl is-enabled/is-active apparmor`; `aa-status` | Enabled and active; 122 profiles loaded, 26 enforcing at the observed check |
| Unattended upgrades | Check service enabled/active and review upgrade log | Enabled and active; log reported no eligible upgrades at that run |
| Auditd | Check service, loaded rules, and `augenrules --check` | Active; nine rules listed; `No change` from rules check |
| Audit watch | Create and remove a harmless test file under `/etc/ufw`; search key `firewall` | Both create and delete events were recorded |
| Sysctl | Read back persisted kernel/network values | ASLR 2; dmesg/kptr restriction 1; protected links 1; forwarding and redirect/source-route acceptance disabled; loose rp_filter 2; SYN cookies enabled |
| Service health | `systemctl --failed --no-pager` | `0 loaded units listed` |
| Ansible outcome | Recorded play recap for SFTP configuration | `ok=17 changed=3 unreachable=0 failed=0` |
| Terraform teardown | Final `terraform destroy` and `terraform state list` | `Destroy complete! Resources: 1 destroyed.`; state list empty |

The tagging API returned stale project-tagged ARNs after teardown. Follow-up EC2 service checks showed the instances terminated and NAT gateway deleted; the endpoint and queried volume returned not found, and a filtered volume query returned no resources. The S3 list request timed out at the endpoint during that check, so it was not treated as independent S3 verification.
