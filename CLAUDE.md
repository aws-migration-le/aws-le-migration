
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repo deploys the **LinkedEye** shared ITSM/monitoring platform infrastructure on AWS for **FinSpot Technology Solutions** (account `654697417727`, region `ap-south-1`). Architecture:
- **EKS** (`linkedeye-finspot-k8s-cluster`, v1.34) — AWS-managed control plane + managed node groups + on-prem hybrid workers per client site
- **Node group `le-mgmt-tools-ng-v2`** (2x m5.xlarge) — All workloads: Jenkins, Harbor, ArgoCD, Keycloak, Vault, ITSM (labels: `role=mgmt-tools`, `jenkins=true`)
- **ALB** (`linkedeye-tools-alb`) — Routes tool and client FQDNs

## AWS CLI Location

AWS CLI v2 is installed at `~/bin/aws` (not `/usr/bin`). Always ensure PATH:
```bash
export PATH="$HOME/bin:$PATH"
```

## Environment Setup

Always source before running any script:
```bash
source .env.shared
```

State IDs (VPC, subnet, SG IDs) are persisted to `/tmp/le-network-ids.env` by each script. If missing after reboot, recover with:
```bash
export VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=LinkedEye --query 'Vpcs[0].VpcId' --output text)
```

## Execution Order

```
Phase A — Network:   01-network/01 → 02 → 03 → 04* → 05 → 06
Phase A — IAM:       02-iam/01 → 02 → 03
Phase B — Compute:   04-compute/01 → 05 → 06   (scripts 02–04 do not exist)
Phase C — EKS:       06-kubernetes/04 → 05 → 06 → 07(optional) → 08 → 11
Phase F — ALB:       05-loadbalancer/01 → 02
Phase E — Deploy:    SSH to EC2s → docker compose up   (compose file on EC2-B at ~/docker-compose.yml)
Phase X — Enterprise: 12-enterprise/01 → 02 → ... → 16  (hardening, KMS, WAF, Velero, monitoring)
Phase V — Validate:  10-validation/01
Phase H — Cleanup:   11-cleanup/01
```

`*` Phase 1 Step 4 (VPN): skip until network team provides FortiGate public IP.

## State File Pattern

Every script appends its resource IDs to `/tmp/le-network-ids.env` (created fresh by `01-network/01-create-vpc.sh`). All subsequent scripts `source /tmp/le-network-ids.env` to read IDs produced by earlier steps. This file is lost on reboot — recover IDs by querying AWS with `Name=tag:Project,Values=LinkedEye` filters.

## .env.shared

`.env.shared` CIDRs and cluster names match the deployed infrastructure. The deployed resource IDs in the state table below are authoritative — verified against live AWS on 2026-03-30.

## Current Deployment State

| Resource | ID | Status |
|---|---|---|
| VPC (10.15.0.0/16) | `vpc-01d43b65392eb7364` | Done |
| Public Subnet AZ1a | `subnet-0bdc4533ee62b2d3c` (10.15.1.0/24) | Done |
| Public Subnet AZ1b | `subnet-054e0299c17cd8792` (10.15.2.0/24) | Done |
| Private Subnet AZ1a | `subnet-0f5887a9f7bd825d6` (10.15.10.0/24) | Done |
| Private Subnet AZ1b | `subnet-05cd5f6bf97410bc5` (10.15.11.0/24) | Done |
| Storage AZ1a | `subnet-05bc39de32b347f04` (10.15.20.0/24) | Done |
| Storage AZ1b | `subnet-0fba24a417964ab69` (10.15.21.0/24) | Done |
| IGW | `igw-02b8ef9f5e002f482` | Done |
| NAT GW | — | Not deployed |
| SSH Key | `~/.ssh/le-shared-k8s-key.pem` | Done |
| EKS Cluster | `linkedeye-finspot-k8s-cluster` (v1.34, logging disabled) | Done |
| EKS Node Group | `le-mgmt-tools-ng-v2` (2x m5.xlarge, AL2, nodes at v1.31) | Done* |
| EKS Addons | vpc-cni, coredns, kube-proxy, ebs-csi, guardduty-agent | Done |
| ALB | `linkedeye-tools-alb` (2 EIPs: 3.109.131.36, 43.205.77.93) | Done |
| Security Groups | eks-cluster, eks-hybrid, jenkins-ec2, mgmt-ec2, alb, guardduty | Done |
| IAM Roles | eks-cluster, eks-nodegroup, eks-hybrid-node, mgmt-ec2, container-insights, velero-irsa | Done |
| KMS Keys | linkedeye-kms-eks, linkedeye-kms-vault, linkedeye-kms-ebs | Done |
| WAF | `linkedeye-waf` | Done |
| GuardDuty | Detector `fa47792e40684b45bfa76c1b4a1a48a4` | Done |
| VPC Flow Logs | `/aws/vpc/flowlogs/linkedeye` (90-day retention) | Done |
| S3 — Velero | `linkedeye-velero-backups-654697417727` | Done |
| S3 — Audit | `linkedeye-audit-logs-654697417727` | Done |
| Hybrid Nodes | On-prem per client (15 clients, 2 nodes each) | Pending (no VPN — public API) |
| Client Namespaces | 15 prod + 3 non-prod | Script ready (06-kubernetes/11) |
| Client ALB Rules | 15 client FQDNs (fs-le-*.finspot.in) | Script ready (05-loadbalancer/02) |
| VPN | — | NOT NEEDED (hybrid nodes use public EKS API) |

## Architecture

```
VPC 10.15.0.0/16  (ap-south-1)
  Public 10.15.1.0/24 (AZ1a) — EKS node groups (Jenkins + Mgmt), ALB
  Public 10.15.2.0/24 (AZ1b) — ALB 2nd AZ
  Private 10.15.10.0/24 (AZ1a) — EKS control plane ENIs
  Private 10.15.11.0/24 (AZ1b) — EKS control plane ENIs
  Storage 10.15.20.0/24 (AZ1a) — reserved
  Storage 10.15.21.0/24 (AZ1b) — reserved

EKS: linkedeye-finspot-k8s-cluster (Control plane K8s 1.34, logging disabled)
  Control plane: AWS-managed (public+private endpoint)
  Node group: le-mgmt-tools-ng-v2 (2x m5.xlarge, AL2, nodes at v1.31*)
    Labels: role=mgmt-tools, jenkins=true, project=linkedeye
  Hybrid workers: On-prem per client site (SSM Hybrid Activation, public EKS API)
  Each client node labeled: client=<name>

* Node group needs AL2023 AMI to upgrade from v1.31 → v1.34 (AL2 supports ≤1.32 only)

ALB: linkedeye-tools-alb → EKS node groups
```

## Key Configuration

- **AMI:** `ami-0f58b397bc5c1f2e8` (Ubuntu 22.04 LTS, ap-south-1)
- **EKS:** Control plane v1.34, single node group `le-mgmt-tools-ng-v2` (2x m5.xlarge, nodes at v1.31 — AL2 AMI); to upgrade nodes to v1.34, create new node group with AL2023 AMI type
- **SSH key:** `~/.ssh/le-shared-k8s-key.pem`
- **Management tools:** Running as pods on EKS node groups (not standalone EC2s)
- **VPN:** Set `FORTIGATE_PUBLIC_IP` in `.env.shared` then run `01-network/04-create-vpn.sh`

## Hybrid Node Registration (per client)

The 15 client names, on-prem CIDRs, FQDNs, and firewall rules are **hardcoded** in `06-kubernetes/05-setup-hybrid-nodes.sh`. Edit that file to add/remove clients.

```bash
# List all 15 clients with their subnets/namespaces:
bash 06-kubernetes/05-setup-hybrid-nodes.sh list

# Generate registration commands for one client's on-prem servers:
bash 06-kubernetes/05-setup-hybrid-nodes.sh register <client-name>

# Print FortiGate outbound firewall rules needed:
bash 06-kubernetes/05-setup-hybrid-nodes.sh firewall <client-name>
```

## Validate Full Deployment

```bash
source .env.shared
bash 10-validation/01-validate-all.sh
# Prints [PASS]/[FAIL] for every resource: VPC, EKS, EC2s, tools, KMS, WAF, Velero, etc.
```

## Enterprise Hardening (Phase 12)

Scripts in `12-enterprise/` should run after EKS and EC2s are up:
- `01-04`: KMS keys, EKS encryption, IMDSv2, Pod Security Standards
- `05`: RBAC (client-admin roles per namespace)
- `06`: Vault TLS + KMS auto-unseal
- `07-08`: VPC Flow Logs, GuardDuty
- `09-10`: Container Insights, Resource Quotas
- `11`: kube-prometheus-stack (Prometheus/Grafana, Alertmanager → StackStorm `st2api:9101`)
- `12-13`: External Secrets Operator (Vault→K8s), Velero backup (S3 bucket `${PROJECT}-velero-backups-654697417727`)
- `14-16`: WAF, EBS encryption, CloudTrail audit logging

## TLS / Certificates

TLS is handled via **ACM certificates on the ALB** (not self-managed). Provision certs in ACM for `*.finspot.in` before creating the HTTPS listener in `05-loadbalancer/01`. Domain certs for `finspot.in` are in `finspot.in-2025/`.

## Archived Scripts

`_archive/` contains the old kubeadm-based setup (bastion, master/worker EC2 launch, Helm deployments for Jenkins/ArgoCD/Harbor/Keycloak/Vault, nginx-ingress). These are superseded by the EKS Hybrid approach and Docker Compose on EC2-B.

## Vault Secret Path Convention

```
secret/le-{client}-prod/*
```

## Alert Routing (StackStorm)

13 Alertmanager receivers → StackStorm `st2api:9101`. Alert state `le_code`: 0=Critical, 1=Warning, 2=OK, 4=Disabled, 5=Placeholder.

## Monthly Cost (AWS ap-south-1)

| Period | Cost | Notes |
|---|---|---|
| March 2026 (actual) | **$874** | Incl. EKS extended support ($223) + 3 node groups |
| April 2026 (projected) | **~$510** | After 2026-03-30 optimizations |
| **Monthly saving** | **$364** | EKS v1.34 upgrade + CW logging disabled |

**April breakdown:** EC2 $140 · EKS control plane $73 · Hybrid nodes $53 · EBS $40 · Tax(GST) $56 · ALB $13 · VPC $13 · Other $10 · CloudWatch $3

Daily run rate: **~$17/day** (was $31/day before optimizations)

## Contacts

| Role | Name | Phone |
|---|---|---|
| CTO / DevOps | Rajkumar Madhu | +91-917-677-2077 |
| Ops Lead | Hoysala Bise | +91-998-014-6101 |
| Network Lead (VPN/FW) | Siva Kadirannagari | +91-960-368-3828 |
| DBA | Rajkumar Ashokan | +91-975-189-2775 |
