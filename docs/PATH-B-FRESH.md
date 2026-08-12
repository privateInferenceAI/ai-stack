# PATH B — Fresh Install via Git (new secrets, new accounts)

**Use for:** a brand-new client deployment. For cloning an existing box, use PATH-A-CLONE.md.
**Basis:** field-proven. Bare g5.2xlarge → verified stack. ~$1.21/hr running — STOP WHEN DONE.

## STAGE 0 — Prerequisites

- This repo, private, on GitHub
- SSH key (`ai-stack-key.pem`), full path known
- AWS console: g5.2xlarge, Ubuntu 24.04, SG inbound 22 only, 200GB gp3, Elastic IP moved

▶ TERMINAL (laptop): `ssh-keygen -R <ELASTIC-IP>`

## STAGE 1 — Foundation

▶ TERMINAL (laptop):
