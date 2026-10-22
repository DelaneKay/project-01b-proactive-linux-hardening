# Design decisions

| Decision | Reason |
| --- | --- |
| Private EC2 nodes with no public addresses | Keep administration and file transfer off the public internet. |
| Session Manager as the administrative path | Avoid inbound SSH and a separate bastion host. |
| SSM port forwarding for SFTP tests | Exercise the SSH/SFTP service without exposing TCP 22 through the VPC security group. |
| Dedicated SFTP account and chroot | Separate file-transfer capability from shell and administrative identities. |
| Separate encrypted target data volume | Keep SFTP data apart from the operating-system root volume and preserve a root-owned chroot root. |
| Deny incoming traffic by default in UFW | Add host-level defense in depth; no exception for public SSH was required. |
| Minimal Session Manager agent permissions | Limit the instance role to the agent's channel operations; keep controller permissions separate. |
| S3 Gateway endpoint and temporary transfer bucket | Route Ansible transfer objects through S3 and restrict access to the lab bucket. |
| One Availability Zone and one NAT Gateway | Keep the learning lab straightforward and lower the number of resources; this is not an HA topology. |
| No forced installation of phased updates | Leave Ubuntu phased rollout behavior intact and recheck updates during a later maintenance window. |
| Private repository during initial setup | Keep the deployment materials private until credentials, identifiers, and evidence have been reviewed for public release. |
