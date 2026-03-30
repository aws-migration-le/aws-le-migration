# LINKEDEYE — Architecture, Connectivity & Flow Guide

**FinSpot Technology Solutions** | AWS Account: 654697417727 | Region: ap-south-1 (Mumbai) | Date: 2026-03-11

---

## 1. Solution Overview

LinkedEye is a shared ITSM/monitoring platform on AWS with **EKS Hybrid Nodes**:
- **AWS (Cloud):** EKS control plane, EC2-A (Jenkins), EC2-B (Mgmt tools), ALB, NAT GW
- **On-Prem (Client Site):** 2 worker nodes per client (HA), FortiGate firewall, NFS server
- **Connection:** Site-to-Site VPN (IPsec IKEv2) between AWS and on-prem

---

## 2. Architecture Diagram

```
                          INTERNET (Users / Admins)
                                   |
                     https://*.finspot.in
                                   |
                         GoDaddy DNS (CNAME)
                                   |
                                   v
            +---------------------------------------+
            |    ALB (Application Load Balancer)     |
            |    linkedeye-tools-alb                 |
            |    Internet-facing, Multi-AZ           |
            |    TLS 1.3 (GoDaddy SSL *.finspot.in) |
            |    AZ1a + AZ1b                         |
            +---+-------+-------+-------+-------+---+
                |       |       |       |       |
    jenkins. argocd. harbor. keycloak. vault.  fs-le-dev-inc.
    finspot  finspot  finspot  finspot  finspot  finspot.in
       |       |       |       |       |       |
  =================================================================
    PUBLIC SUBNET (10.100.1.0/24 + 10.100.2.0/24)
  =================================================================
                |                         |
   +------------------+     +---------------------------+
   | EC2-A (Jenkins)  |     | EC2-B (Mgmt+ITSM)        |
   | m5.large         |     | m5.xlarge                 |
   | 13.232.32.128    |     | 13.201.36.214             |
   | (EIP)            |     | 10.100.1.92 (private)     |
   | 10.100.1.244     |     |                           |
   |                  |     | Harbor    :5000/:8083      |
   | Jenkins  :8080   |     | ArgoCD    :8082            |
   |                  |     | Keycloak  :8081            |
   |                  |     | Vault     :8200            |
   |                  |     | PostgreSQL:5432            |
   |                  |     | ITSM      :80              |
   +------------------+     +---------------------------+
                                       |
               +---------------------------+
               | NAT Gateway               |
               | 13.233.176.240 (EIP)      |
               | Private subnet → Internet |
               +---------------------------+
                            |
  =================================================================
    PRIVATE SUBNETS (EKS Control Plane ENIs)
  =================================================================
                            |
   +------------------------------------------------+
   |         EKS CONTROL PLANE (AWS Managed)         |
   |         le-shared-eks  v1.31  ACTIVE            |
   |                                                  |
   |  +----------+  +----------+  +----------+       |
   |  |API Server|  |API Server|  |API Server|       |
   |  | (AZ 1a)  |  | (AZ 1b)  |  | (AZ 1c)  |       |
   |  +----------+  +----------+  +----------+       |
   |  +----------+  +----------+  +----------+       |
   |  |  etcd    |  |  etcd    |  |  etcd    |       |
   |  | (AZ 1a)  |  | (AZ 1b)  |  | (AZ 1c)  |       |
   |  +----------+  +----------+  +----------+       |
   |                                                  |
   |  ENIs: 10.100.11.0/24, 10.100.12.0/24,         |
   |        10.100.1.0/24                             |
   |  Addons: vpc-cni, coredns, kube-proxy, ebs-csi  |
   |  HA: 99.95% SLA, 3-AZ redundancy                |
   +------------------------+-------------------------+
                            |
                      IPsec VPN Tunnel
                      (IKEv2, BGP)
                      AWS VGW <--> FortiGate
                            |
  =================================================================
    ON-PREM CLIENT SITE (via VPN)
  =================================================================
                            |
   +------------------------------------------------+
   |           ON-PREM (Client Site)                  |
   |                                                  |
   |   +-------------------+                          |
   |   | FortiGate Firewall|  <-- VPN Endpoint        |
   |   +-------------------+                          |
   |           |                                      |
   |   +-------+--------+--------+                    |
   |   |                |        |                    |
   |   v                v        v                    |
   |   +-----------+ +-----------+ +-----------+     |
   |   | Worker    | | Worker    | | NFS       |     |
   |   | Node 1    | | Node 2    | | Server    |     |
   |   | (EKS      | | (EKS      | | (Shared   |     |
   |   |  Hybrid)  | |  Hybrid)  | |  Storage) |     |
   |   |           | |           | |           |     |
   |   | Pod A-1   | | Pod A-2   | |           |     |
   |   | Pod B-1   | | Pod B-2   | |           |     |
   |   +-----------+ +-----------+ +-----------+     |
   |                                                  |
   |   HA: 2 nodes, pods spread via anti-affinity     |
   |   PDB: minAvailable=1 (always 1 pod running)    |
   +--------------------------------------------------+
```

---

## 3. Network Architecture & Subnets

**VPC:** `10.100.0.0/16` (vpc-0b902465605d6c6d6)

| Subnet | CIDR | AZ | Type | Purpose | ID |
|--------|------|----|------|---------|------|
| le-public-1a | 10.100.1.0/24 | ap-south-1a | Public | EC2-A, EC2-B, NAT GW, ALB | subnet-074f1da66fc7166fb |
| le-public-1b | 10.100.2.0/24 | ap-south-1b | Public | ALB 2nd AZ | subnet-0b0e89de77a4c35a1 |
| le-k8s-private-1a | 10.100.10.0/24 | ap-south-1a | Private | Available (future use) | subnet-065784ff2566bace7 |
| le-eks-private-1b | 10.100.11.0/24 | ap-south-1b | Private | EKS control plane ENIs | subnet-081fd4945c6460889 |
| le-eks-private-1c | 10.100.12.0/24 | ap-south-1c | Private | EKS control plane ENIs | subnet-0d7fda38d5e1b0566 |

---

## 4. All IP Addresses & Endpoints

### Public IPs (Internet-Facing)

| Resource | Public IP | Private IP | Purpose |
|----------|-----------|------------|---------|
| EC2-A (Jenkins) | **13.232.32.128** (EIP) | 10.100.1.244 | Jenkins CI/CD, SSH access |
| EC2-B (Mgmt+ITSM) | **13.201.36.214** | 10.100.1.92 | Harbor, ArgoCD, Keycloak, Vault, ITSM, PostgreSQL |
| NAT Gateway | **13.233.176.240** (EIP) | - | Private subnet outbound traffic |
| ALB | **linkedeye-tools-alb-410755002.ap-south-1.elb.amazonaws.com** | Dynamic | HTTPS load balancing (*.finspot.in) |

### EKS Endpoint

| Resource | Endpoint | Access |
|----------|----------|--------|
| EKS API | `https://6AA304CECC2E9D35F6B43EDF4FC8CBA2.gr7.ap-south-1.eks.amazonaws.com` | Public + Private |
| EKS Version | v1.31 | - |

---

## 5. Traffic Flows (Step-by-Step)

### Flow 1: User Accesses Tools (HTTPS)

```
User Browser → jenkins.finspot.in
  Step 1: DNS resolves → CNAME → ALB DNS
  Step 2: ALB receives on :443 (TLS 1.3)
  Step 3: ALB checks Host header → matches jenkins.finspot.in
  Step 4: ALB forwards to Target Group → EC2-A:8080
  Step 5: Jenkins responds → ALB → User
```

### Flow 2: CI/CD Pipeline (Build & Deploy)

```
Developer → Git Push
     |
     v
Jenkins (EC2-A:8080)
     |
     | 1. Build Docker Image
     | 2. Push to Harbor
     v
Harbor (EC2-B:5000)
     |
     | 3. Update K8s manifests in Git
     v
ArgoCD (EC2-B:8082)
     |
     | 4. Sync to EKS
     v
EKS Control Plane
     |
     | 5. Schedule pods (via VPN)
     v
On-Prem Worker-1 [Pod replica-1]
On-Prem Worker-2 [Pod replica-2]
```

### Flow 3: On-Prem Workers <-> EKS (VPN)

```
ON-PREM                                    AWS
+------------------+                       +------------------+
| Worker Node 1    |                       | EKS API Server   |
| Worker Node 2    |                       | :443             |
|   (kubelet)      |                       |                  |
+--------+---------+                       +--------+---------+
         |                                          |
         v                                          v
+------------------+    IPsec VPN Tunnel   +------------------+
| FortiGate FW     | ==================== | AWS VPN Gateway  |
| ASN: 65000       |   IKEv2 / AES-256    | ASN: 64512       |
+------------------+   UDP 500 + 4500     +------------------+

Traffic over VPN:
  Worker → EKS API     : 443  (kubelet heartbeat, pod scheduling)
  Worker → Harbor      : 5000 (pull container images)
  Worker → Vault       : 8200 (fetch secrets)
  Worker → PostgreSQL  : 5432 (database access)
  EKS    → Worker      : 10250 (kubelet API, logs, exec)
```

### Flow 4: Outbound from Private Subnet

```
EKS Control Plane (private) → NAT GW (13.233.176.240) → IGW → Internet
```

### Flow 5: SSH Access (Admin)

```
EC2-A: ssh ubuntu@13.232.32.128 -i ~/.ssh/le-shared-k8s-key.pem
EC2-B: ssh ubuntu@13.201.36.214 -i ~/.ssh/le-shared-k8s-key.pem
(Direct SSH from office — public subnet, no bastion)
```

---

## 6. EKS HA Architecture

### Control Plane HA (AWS-Managed, Automatic)

| Component | HA Level | Details |
|-----------|----------|---------|
| API Server | 3 replicas / 3 AZ | Load balanced, auto-healing |
| etcd | 3 nodes / 3 AZ | Quorum-based, encrypted |
| CoreDNS | 2 replicas | Cluster DNS resolution |
| SLA | 99.95% | AWS managed uptime guarantee |

### Worker Node HA (2 Nodes per Client)

| Feature | Setting | What It Does |
|---------|---------|--------------|
| Replicas | 2 | 1 pod per worker node |
| Pod Anti-Affinity | preferredDuringScheduling | Spread pods across nodes |
| PodDisruptionBudget | minAvailable: 1 | Always 1 pod running during maintenance |
| Rolling Update | maxUnavailable: 1 | Update one at a time, zero downtime |
| Liveness Probe | HTTP /health | Auto-restart crashed pods |
| Readiness Probe | HTTP /ready | Remove unhealthy from service |
| Priority Class | le-critical (1M) | Critical pods never preempted |
| Network Policy | Namespace isolation | Pods only talk within namespace |

### Failure Scenarios

```
SCENARIO 1: Worker Node 1 goes down
  Before:  Worker-1 [Pod-A]       Worker-2 [Pod-B]
  After:   Worker-1 [DOWN]        Worker-2 [Pod-B, Pod-A]
  Result:  ZERO DOWNTIME — K8s reschedules to Worker-2

SCENARIO 2: Pod crashes
  Before:  Worker-1 [Pod-A CRASH] Worker-2 [Pod-B OK]
  After:   Worker-1 [Pod-A OK]    Worker-2 [Pod-B OK]
  Result:  ZERO DOWNTIME — Liveness probe restarts in ~30s

SCENARIO 3: Rolling deployment
  Step 1:  Worker-1 [v1->v2]      Worker-2 [v1]     (PDB: min 1)
  Step 2:  Worker-1 [v2]          Worker-2 [v1->v2]
  Result:  ZERO DOWNTIME — One pod always running

SCENARIO 4: Both workers down
  Result:  OUTAGE — EKS control plane still healthy
           Pods auto-reschedule when any node returns
```

---

## 7. ALB Host-Based Routing

| Domain | Target Group | Target | Port | Service |
|--------|-------------|--------|------|---------|
| jenkins.finspot.in | linkedeye-tg-jenkins | EC2-A | 8080 | Jenkins CI/CD |
| argocd.finspot.in | linkedeye-tg-argocd | EC2-B | 8082 | ArgoCD GitOps |
| harbor.finspot.in | linkedeye-tg-harbor | EC2-B | 8083 | Harbor Registry |
| keycloak.finspot.in | linkedeye-tg-keycloak | EC2-B | 8081 | Keycloak SSO |
| vault.finspot.in | linkedeye-tg-vault | EC2-B | 8200 | HashiCorp Vault |
| fs-le-dev-inc.finspot.in | linkedeye-tg-itsm | EC2-B | 80 | ITSM Platform |

- **SSL:** GoDaddy wildcard (*.finspot.in), imported to ACM
- **TLS Policy:** TLS 1.3
- **HTTP->HTTPS:** Port 80 redirects to 443

---

## 8. Security Controls

| Control | Implementation | Status |
|---------|---------------|--------|
| TLS 1.3 | ALB HTTPS with GoDaddy SSL | Active |
| IMDSv2 Enforced | HttpTokens=required on all EC2s | Active |
| Pod Security Standards | le-workloads=restricted, le-monitoring=baseline | Active |
| RBAC | 4 ClusterRoles (argocd, jenkins, prometheus, client-admin) | Active |
| Network Policy | Namespace isolation for le-workloads | Active |
| EKS Secrets Encryption | KMS envelope encryption | Active |
| GuardDuty | EKS Audit + Runtime monitoring | Active |
| CloudTrail | Multi-region audit logging | Active |
| On-Prem Firewall | FortiGate (replaces AWS WAF) | On-Prem |
| VPN Encryption | IPsec IKEv2 (AES-256) | Pending |

---

## 9. Network Team Requirements (For Siva)

### What We Need from Siva

1. **FortiGate Public IP address** — needed to create AWS Site-to-Site VPN
2. **On-prem network CIDR** — currently assumed `10.15.0.0/24`, confirm actual range
3. **FortiGate VPN configuration** — apply settings below

### VPN Configuration for FortiGate

| Parameter | Value |
|-----------|-------|
| VPN Type | Site-to-Site (IPsec IKEv2) |
| AWS VPC CIDR | **10.100.0.0/16** |
| On-Prem CIDR | **10.15.0.0/24** (confirm with Siva) |
| AWS BGP ASN | **64512** |
| On-Prem BGP ASN | **65000** |
| Encryption | AES-256-GCM |
| Integrity | SHA-256 |
| DH Group | 14 (2048-bit) |
| IKE Version | IKEv2 |
| Dead Peer Detection | Enabled |

### Ports to Open on FortiGate

| Direction | Source | Destination | Port | Purpose |
|-----------|--------|------------|------|---------|
| On-Prem → AWS | Worker Nodes | EKS API Endpoint | 443 | kubelet → API Server |
| On-Prem → AWS | Worker Nodes | 10.100.1.92 (EC2-B) | 5000 | Pull images from Harbor |
| On-Prem → AWS | Worker Nodes | 10.100.1.92 (EC2-B) | 8200 | Fetch secrets from Vault |
| On-Prem → AWS | Worker Nodes | 10.100.1.92 (EC2-B) | 5432 | PostgreSQL database |
| AWS → On-Prem | EKS Control Plane | Worker Nodes | 10250 | kubelet API (logs, exec) |
| AWS → On-Prem | EKS Control Plane | Worker Nodes | 4789 | VXLAN overlay (pod-to-pod) |
| Both | VPN Tunnel | VPN Tunnel | UDP 500, 4500 | IPsec IKE + NAT-T |

### AWS IPs to Whitelist on FortiGate

| IP | What | Why Whitelist |
|----|------|---------------|
| **13.233.176.240** | NAT Gateway | AWS private subnet outbound |
| **13.232.32.128** | EC2-A (Jenkins) | CI/CD server |
| **13.201.36.214** | EC2-B (Mgmt) | Harbor, ArgoCD, Vault, PostgreSQL |
| **10.100.0.0/16** | AWS VPC CIDR | All VPN traffic from AWS |

### VPN Connectivity Diagram

```
AWS SIDE                                     ON-PREM SIDE
+-------------------+                        +-------------------+
| VPC 10.100.0.0/16 |                        | LAN 10.15.0.0/24  |
|                   |                        |                   |
| EC2-A  .1.244     |                        | Worker-1          |
| EC2-B  .1.92      |     IPsec VPN          | Worker-2          |
| EKS CP (private)  | ====================== | NFS Server        |
|                   |   IKEv2 / AES-256      |                   |
| VPN Gateway       | <--------------------> | FortiGate FW      |
| ASN: 64512        |   UDP 500 + 4500       | ASN: 65000        |
+-------------------+                        +-------------------+
```

---

## 10. Client On-Prem Setup Guide

### Hardware Required (Per Client Site)

- **2x Worker Servers** (for HA) — Min: 4 vCPU, 16 GB RAM, 100 GB disk, Ubuntu 22.04
- **1x NFS Server** — Shared storage
- **Network** — Access to FortiGate VPN

### Node Registration Steps

```
Step 1: VPN tunnel established (Siva + AWS team)
Step 2: Generate commands:  ./05-setup-hybrid-nodes.sh register <client-name>
Step 3: Run commands on both worker servers (SSM + nodeadm)
Step 4: Nodes appear as Ready in EKS cluster
Step 5: Label nodes:  kubectl label node <name> client=<client-name>
Step 6: Deploy workloads (2 replicas, HA auto-applied)
```

### Client Onboarding Flow

```
Step 1: VPN Setup
  Siva provides FortiGate IP → AWS VPN created → Tunnel UP

Step 2: Register 2 Worker Nodes
  ./05-setup-hybrid-nodes.sh register acme-corp
  → Run output on Worker-1 and Worker-2

Step 3: Verify
  $ kubectl get nodes -l client=acme-corp
  NAME                STATUS   ROLES    VERSION
  acme-corp-worker-1  Ready    <none>   v1.31
  acme-corp-worker-2  Ready    <none>   v1.31

Step 4: Deploy Workloads (HA)
  $ kubectl apply -f acme-corp-deployment.yaml
  → 2 replicas (1 per node)
  → PDB ensures 1 always running
  → Anti-affinity spreads across nodes
```

---

## 11. Contacts

| Role | Name | Phone | Responsibility |
|------|------|-------|---------------|
| CTO / DevOps | Rajkumar Madhu | +91-917-677-2077 | Architecture, AWS, EKS, CI/CD |
| Ops Lead | Hoysala Bise | +91-998-014-6101 | Day-to-day operations |
| Network Lead | Siva Kadirannagari | +91-960-368-3828 | VPN, FortiGate, firewall rules |
| DBA | Rajkumar Ashokan | +91-975-189-2775 | PostgreSQL, database |

---

## Quick Summary

### What's Running

- VPC + 5 Subnets + IGW + NAT GW
- EC2-A (Jenkins) — m5.large, 13.232.32.128
- EC2-B (Mgmt+ITSM) — m5.xlarge, 13.201.36.214
- EKS v1.31 (HA control plane, 3 AZ)
- ALB (6 host routes, TLS 1.3)
- HA configs applied (PDB, anti-affinity, NetworkPolicy, PriorityClass)

### What's Pending

- VPN — need FortiGate IP from Siva
- DNS CNAME — *.finspot.in → ALB
- Docker Compose — start services on EC2s
- Worker Nodes — join after VPN is up
- Client workload deployment

**Monthly Cost:** ~$404/month | **Region:** ap-south-1 (Mumbai) | **EKS SLA:** 99.95%

---

*LinkedEye Infrastructure | FinSpot Technology Solutions | 2026-03-11 | Confidential*
