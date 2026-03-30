# LinkedEye Platform - End-to-End Deployment Guide
# FinSpot Technology Solutions
# AWS Account: 654697417727 | Region: ap-south-1 (Mumbai)
# Date: 2026-03-07

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 — VPC & Network Setup](#3-phase-1--vpc--network-setup)
4. [Phase 2 — Security Groups](#4-phase-2--security-groups)
5. [Phase 3 — EC2 Instances (Master & Worker)](#5-phase-3--ec2-instances)
6. [Phase 4 — Elastic IPs & Internet Access](#6-phase-4--elastic-ips--internet-access)
7. [Phase 5 — Kubernetes Cluster Init (kubeadm)](#7-phase-5--kubernetes-cluster-init)
8. [Phase 6 — Calico CNI Setup](#8-phase-6--calico-cni-setup)
9. [Phase 7 — Worker Node Join](#9-phase-7--worker-node-join)
10. [Phase 8 — Kubernetes Namespaces & Storage](#10-phase-8--namespaces--storage)
11. [Phase 9 — Helm Setup](#11-phase-9--helm-setup)
12. [Phase 10 — PostgreSQL (Centralized Database)](#12-phase-10--postgresql)
13. [Phase 11 — Deploy Shared Tools](#13-phase-11--deploy-shared-tools)
14. [Phase 12 — NGINX Ingress Controller](#14-phase-12--nginx-ingress-controller)
15. [Phase 13 — AWS Application Load Balancer](#15-phase-13--aws-alb)
16. [Phase 14 — DNS Configuration](#16-phase-14--dns-configuration)
17. [Phase 15 — Vault Init & Unseal](#17-phase-15--vault-init--unseal)
18. [Phase 16 — Database Backup (MinIO CronJob)](#18-phase-16--database-backup)
19. [Current Status & Pending Items](#19-current-status--pending-items)
20. [Troubleshooting Reference](#20-troubleshooting-reference)
21. [All Credentials Reference](#21-all-credentials-reference)

---

## 1. Architecture Overview

```
                         ┌─────────────────────────────────────────────────────────┐
                         │                    AWS VPC 10.100.0.0/16                │
                         │                     (ap-south-1)                        │
                         │                                                         │
   Internet ──► IGW ─────┤   Public Subnet 10.100.1.0/24 (AZ: ap-south-1a)       │
                         │     └─ NAT Gateway (for future private-only nodes)      │
                         │                                                         │
                         │   K8s Private Subnet 10.100.10.0/24 (AZ: ap-south-1a)  │
                         │     ├─ Master: 10.100.10.10 (m5.2xlarge) EIP: 13.201.105.154
                         │     └─ Worker: 10.100.10.20 (m5.4xlarge) EIP: 13.201.209.63
                         │                                                         │
                         │   Future EKS 10.100.11.0/24 (AZ: ap-south-1b)          │
                         │   Future EKS 10.100.12.0/24 (AZ: ap-south-1c)          │
                         └─────────────────────────────────────────────────────────┘

   ALB (le-k8s-alb) ──► Worker NodePort 30080 ──► NGINX Ingress ──► K8s Services

   K8s Namespaces:
   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │   le-cicd    │  │ le-security  │  │le-monitoring │  │ ingress-nginx│
   │              │  │              │  │              │  │              │
   │ Jenkins      │  │ Keycloak     │  │  (future)    │  │ NGINX Ingress│
   │ ArgoCD       │  │ Vault        │  │              │  │ Controller   │
   │ Harbor       │  │              │  │              │  │              │
   │ MinIO        │  │              │  │              │  │              │
   │ PostgreSQL   │  │              │  │              │  │              │
   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
```

### Key Specifications

| Component | Value |
|---|---|
| AWS Account | 654697417727 |
| Region | ap-south-1 (Mumbai) |
| VPC CIDR | 10.100.0.0/16 |
| K8s Version | v1.29.15 (kubeadm) |
| CNI | Calico (IPIP encapsulation) |
| Pod CIDR | 192.168.0.0/16 |
| Service CIDR | 172.20.0.0/16 |
| Storage Class | local-path (Rancher local-path-provisioner) |
| OS | Ubuntu 22.04 LTS (AMI: ami-0f58b397bc5c1f2e8) |

---

## 2. Prerequisites

### 2.1 AWS CLI Setup

```bash
# AWS CLI v2 installed at ~/bin/aws
export PATH="$HOME/bin:$PATH"

# Verify
aws --version
# aws-cli/2.x.x ...

# Configure credentials
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: ap-south-1
# Default output: json
```

### 2.2 SSH Key Pair

```bash
# Create SSH key pair
aws ec2 create-key-pair \
  --key-name le-shared-k8s-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/le-shared-k8s-key.pem

chmod 400 ~/.ssh/le-shared-k8s-key.pem
```

### 2.3 Environment Variables

```bash
source .env.shared
```

---

## 3. Phase 1 — VPC & Network Setup

### Step 1: Create VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.100.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=le-shared-vpc},{Key=Project,Value=LinkedEye}]' \
  --query 'Vpc.VpcId' --output text)

# Enable DNS resolution and hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

echo "VPC_ID=$VPC_ID"
# Result: vpc-0b902465605d6c6d6
```

### Step 2: Create Subnets

```bash
# Public Subnet (10.100.1.0/24) — for NAT GW, ALB
PUB_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.100.1.0/24 \
  --availability-zone ap-south-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=le-public-subnet-1a},{Key=Project,Value=LinkedEye}]' \
  --query 'Subnet.SubnetId' --output text)

# Enable auto-assign public IP on public subnet
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch

# K8s Private Subnet (10.100.10.0/24) — Master + Worker nodes
PRIV_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.100.10.0/24 \
  --availability-zone ap-south-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=le-k8s-private-1a},{Key=Project,Value=LinkedEye}]' \
  --query 'Subnet.SubnetId' --output text)

# Future EKS Subnets (for multi-AZ)
PRIV_SUBNET_1B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.100.11.0/24 \
  --availability-zone ap-south-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=le-eks-private-1b},{Key=Project,Value=LinkedEye}]' \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET_1C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.100.12.0/24 \
  --availability-zone ap-south-1c \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=le-eks-private-1c},{Key=Project,Value=LinkedEye}]' \
  --query 'Subnet.SubnetId' --output text)

# ALB requires subnets in 2 AZs — create public subnet in 1b
PUB_SUBNET_1B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.100.2.0/24 \
  --availability-zone ap-south-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=le-public-subnet-1b},{Key=Project,Value=LinkedEye}]' \
  --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_1B --map-public-ip-on-launch
```

**Subnet Summary:**

| Subnet | CIDR | AZ | Purpose | ID |
|---|---|---|---|---|
| Public 1a | 10.100.1.0/24 | ap-south-1a | NAT GW, ALB | subnet-074f1da66fc7166fb |
| Public 1b | 10.100.2.0/24 | ap-south-1b | ALB (2nd AZ) | subnet-0b0e89de77a4c35a1 |
| K8s Private | 10.100.10.0/24 | ap-south-1a | Master + Worker | subnet-065784ff2566bace7 |
| EKS Private 1b | 10.100.11.0/24 | ap-south-1b | Future EKS | subnet-081fd4945c6460889 |
| EKS Private 1c | 10.100.12.0/24 | ap-south-1c | Future EKS | subnet-0d7fda38d5e1b0566 |

### Step 3: Internet Gateway

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=le-igw},{Key=Project,Value=LinkedEye}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
# Result: igw-03f7860ecc90aafd4
```

### Step 4: NAT Gateway

```bash
# Allocate Elastic IP for NAT GW
NAT_EIP=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=le-nat-eip},{Key=Project,Value=LinkedEye}]' \
  --query 'AllocationId' --output text)

# Create NAT Gateway in public subnet
NAT_GW=$(aws ec2 create-nat-gateway \
  --subnet-id $PUB_SUBNET \
  --allocation-id $NAT_EIP \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=le-nat-gw},{Key=Project,Value=LinkedEye}]' \
  --query 'NatGateway.NatGatewayId' --output text)

# Wait for NAT GW to become available (~2 min)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW
# Result: nat-06401f68c43ff9511
```

### Step 5: Route Tables

```bash
# Public Route Table — routes to Internet Gateway
PUB_RTB=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=le-public-rtb},{Key=Project,Value=LinkedEye}]' \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id $PUB_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB_SUBNET_1B

# Private Route Table — routes to IGW (since we use EIPs on nodes)
PRIV_RTB=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=le-private-rtb},{Key=Project,Value=LinkedEye}]' \
  --query 'RouteTable.RouteTableId' --output text)

# NOTE: Initially this pointed to NAT GW, changed to IGW after assigning EIPs to nodes
aws ec2 create-route --route-table-id $PRIV_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PRIV_RTB --subnet-id $PRIV_SUBNET
```

> **Note:** The private route table was initially set to NAT GW. After assigning Elastic IPs directly to master/worker nodes, it was changed to IGW for direct internet access.

---

## 4. Phase 2 — Security Groups

### Step 1: Master Node Security Group

```bash
SG_MASTER=$(aws ec2 create-security-group \
  --group-name le-k8s-master-sg \
  --description "LinkedEye K8s Master Node" \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=le-k8s-master-sg},{Key=Project,Value=LinkedEye}]' \
  --query 'GroupId' --output text)
# Result: sg-041ea1d03d124de1f

# SSH from anywhere (since nodes have public EIPs)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

# K8s API server
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 6443 --cidr 10.100.0.0/16

# etcd
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 2379-2380 --cidr 10.100.10.0/24

# kubelet
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 10250 --cidr 10.100.10.0/24

# kube-scheduler
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 10259 --cidr 10.100.10.0/24

# kube-controller-manager
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 10257 --cidr 10.100.10.0/24

# CRITICAL: All traffic within K8s subnet (required for Calico IPIP encapsulation)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol -1 --cidr 10.100.10.0/24

# Port-forward access (tools on master via EIP)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 8080-8090 --cidr 0.0.0.0/0

# Vault UI port
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 8200 --cidr 0.0.0.0/0

# MinIO console port
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
  --protocol tcp --port 9001 --cidr 0.0.0.0/0
```

### Step 2: Worker Node Security Group

```bash
SG_WORKER=$(aws ec2 create-security-group \
  --group-name le-k8s-worker-sg \
  --description "LinkedEye K8s Worker Node" \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=le-k8s-worker-sg},{Key=Project,Value=LinkedEye}]' \
  --query 'GroupId' --output text)
# Result: sg-0c49310672a092d83

# SSH
aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol tcp --port 22 --cidr 0.0.0.0/0

# kubelet
aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol tcp --port 10250 --cidr 10.100.10.0/24

# NodePort range (for NGINX Ingress)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0

# CRITICAL: All traffic within K8s subnet (Calico IPIP + Typha port 5473)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol -1 --cidr 10.100.10.0/24

# HTTP/HTTPS from ALB
aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
```

### Step 3: ALB Security Group

```bash
SG_ALB=$(aws ec2 create-security-group \
  --group-name le-k8s-alb-sg \
  --description "LinkedEye ALB Security Group" \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=le-k8s-alb-sg},{Key=Project,Value=LinkedEye}]' \
  --query 'GroupId' --output text)
# Result: sg-0cad5f5884025ae0a

aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
```

---

## 5. Phase 3 — EC2 Instances

### Step 1: User Data Script (installed on both nodes via cloud-init)

The user data script pre-installs all Kubernetes dependencies:

```bash
#!/bin/bash
set -ex

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Kernel parameters
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Install containerd
apt-get update && apt-get install -y containerd apt-transport-https ca-certificates curl gpg
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# Install kubeadm, kubelet, kubectl (v1.29)
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "K8s prerequisites installed successfully"
```

### Step 2: Launch Master Node

```bash
MASTER_ID=$(aws ec2 run-instances \
  --image-id ami-0f58b397bc5c1f2e8 \
  --instance-type m5.2xlarge \
  --key-name le-shared-k8s-key \
  --subnet-id $PRIV_SUBNET \
  --security-group-ids $SG_MASTER \
  --private-ip-address 10.100.10.10 \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
  --user-data file://user-data-k8s.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=le-k8s-master},{Key=Project,Value=LinkedEye},{Key=Role,Value=master}]' \
  --query 'Instances[0].InstanceId' --output text)
# Result: i-0254e6bd512f67dd9
```

### Step 3: Launch Worker Node

```bash
WORKER_ID=$(aws ec2 run-instances \
  --image-id ami-0f58b397bc5c1f2e8 \
  --instance-type m5.4xlarge \
  --key-name le-shared-k8s-key \
  --subnet-id $PRIV_SUBNET \
  --security-group-ids $SG_WORKER \
  --private-ip-address 10.100.10.20 \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
  --user-data file://user-data-k8s.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=le-k8s-worker},{Key=Project,Value=LinkedEye},{Key=Role,Value=worker}]' \
  --query 'Instances[0].InstanceId' --output text)
# Result: i-0e0662a64aa8cc8e6
```

### EC2 Instance Summary

| Role | Instance Type | Private IP | vCPU | RAM | Disk | ID |
|---|---|---|---|---|---|---|
| Master | m5.2xlarge | 10.100.10.10 | 8 | 32 GB | 100 GB gp3 | i-0254e6bd512f67dd9 |
| Worker | m5.4xlarge | 10.100.10.20 | 16 | 64 GB | 200 GB gp3 | i-0e0662a64aa8cc8e6 |

---

## 6. Phase 4 — Elastic IPs & Internet Access

Instead of using a bastion host, assign Elastic IPs directly to both nodes for SSH and internet access.

### Step 1: Allocate and Associate EIPs

```bash
# Master EIP
MASTER_EIP=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=le-master-eip},{Key=Project,Value=LinkedEye}]' \
  --query 'AllocationId' --output text)

aws ec2 associate-address --allocation-id $MASTER_EIP --instance-id $MASTER_ID
# Master EIP: 13.201.105.154

# Worker EIP
WORKER_EIP=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=le-worker-eip},{Key=Project,Value=LinkedEye}]' \
  --query 'AllocationId' --output text)

aws ec2 associate-address --allocation-id $WORKER_EIP --instance-id $WORKER_ID
# Worker EIP: 13.201.209.63
```

### Step 2: Disable Source/Dest Check (Required for Calico)

```bash
# CRITICAL: Calico IPIP encapsulation requires source/dest check disabled
aws ec2 modify-instance-attribute --instance-id $MASTER_ID --no-source-dest-check
aws ec2 modify-instance-attribute --instance-id $WORKER_ID --no-source-dest-check
```

### Step 3: SSH Access

```bash
# SSH to Master
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.105.154

# SSH to Worker
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.209.63
```

---

## 7. Phase 5 — Kubernetes Cluster Init

> **Important:** Wait ~5 minutes after EC2 launch for user-data script to complete.

### Step 1: SSH to Master and Initialize

```bash
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.105.154
```

```bash
# Verify prerequisites installed
kubeadm version    # v1.29.x
kubelet --version  # v1.29.x
kubectl version --client  # v1.29.x

# Initialize Kubernetes cluster
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=172.20.0.0/16 \
  --apiserver-advertise-address=10.100.10.10 \
  --kubernetes-version=v1.29.15 \
  --node-name=le-k8s-master
```

### Step 2: Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify
kubectl get nodes
# NAME             STATUS     ROLES           AGE   VERSION
# le-k8s-master    NotReady   control-plane   30s   v1.29.15
```

> **Note:** Node shows `NotReady` until CNI (Calico) is installed.

### Step 3: Save the Join Command

kubeadm init outputs a join command. Save it:

```bash
# Example (your token will be different):
kubeadm join 10.100.10.10:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

If you lose the join token, regenerate:

```bash
kubeadm token create --print-join-command
```

---

## 8. Phase 6 — Calico CNI Setup

### Step 1: Install Calico (on Master)

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
```

### Step 2: Verify Calico Pods

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
# Both pods should show 1/1 Running
```

### Critical Troubleshooting: Calico BGP Issues

If calico-node pods show `0/1 Running` with BGP errors:

```
BGP not established with 10.100.10.20
```

**Root Causes & Fixes:**

1. **EC2 Source/Dest Check:** Must be disabled (see Phase 4 Step 2)

2. **Security Group Rules:** Must allow all traffic within K8s subnet:
   ```bash
   # Add all-protocol rule for K8s subnet on BOTH security groups
   aws ec2 authorize-security-group-ingress --group-id $SG_MASTER \
     --protocol -1 --cidr 10.100.10.0/24
   aws ec2 authorize-security-group-ingress --group-id $SG_WORKER \
     --protocol -1 --cidr 10.100.10.0/24
   ```

3. **Restart calico-node after fixes:**
   ```bash
   kubectl delete pods -n kube-system -l k8s-app=calico-node
   # Pods auto-recreate, wait 30s then verify BGP peered
   kubectl logs -n kube-system -l k8s-app=calico-node | grep "peer"
   # Should see: "1 peer established"
   ```

---

## 9. Phase 7 — Worker Node Join

### Step 1: SSH to Worker

```bash
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.209.63
```

### Step 2: Join the Cluster

```bash
sudo kubeadm join 10.100.10.10:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### Step 3: Verify (on Master)

```bash
kubectl get nodes
# NAME             STATUS   ROLES           AGE    VERSION
# le-k8s-master    Ready    control-plane   10m    v1.29.15
# le-k8s-worker    Ready    <none>          1m     v1.29.15
```

Both nodes should show `Ready` status.

---

## 10. Phase 8 — Namespaces & Storage

### Step 1: Create Namespaces

```bash
kubectl apply -f manifests/namespaces/namespaces.yaml
```

Or manually:

```bash
kubectl create namespace le-cicd
kubectl create namespace le-security
kubectl create namespace le-monitoring
kubectl create namespace ingress-nginx

# Label namespaces
kubectl label ns le-cicd project=linkedeye purpose=ci-cd
kubectl label ns le-security project=linkedeye purpose=security
kubectl label ns le-monitoring project=linkedeye purpose=monitoring
kubectl label ns ingress-nginx project=linkedeye purpose=ingress
```

### Step 2: Install Local-Path-Provisioner (Storage Class)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

# Verify
kubectl get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   10s

# Verify provisioner pod running
kubectl get pods -n local-path-storage
# NAME                                      READY   STATUS    AGE
# local-path-provisioner-xxx                1/1     Running   30s
```

> **Troubleshooting:** If local-path-provisioner shows `CrashLoopBackOff` with "dial tcp 172.20.0.1:443: i/o timeout", fix Calico networking first (Phase 6 troubleshooting).

---

## 11. Phase 9 — Helm Setup

### Step 1: Install Helm v3

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version
# v3.20.x
```

### Step 2: Add Helm Repositories

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add harbor https://helm.goharbor.io
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add minio https://charts.min.io/

helm repo update
```

---

## 12. Phase 10 — PostgreSQL (Centralized Database)

Deploy a centralized PostgreSQL instance for all tools to enable easy backup/restore.

### Step 1: Deploy PostgreSQL

```bash
kubectl apply -f manifests/postgresql/postgresql-deployment.yaml
```

This creates:
- **Secret:** `postgresql-secret` (admin credentials)
- **ConfigMap:** `postgresql-init` (init script for 7 databases)
- **PVC:** `postgresql-data` (50Gi on local-path)
- **Deployment:** PostgreSQL 16 Alpine
- **Service:** `postgresql.le-cicd.svc.cluster.local:5432`

### Step 2: Verify

```bash
kubectl get pods -n le-cicd -l app=postgresql
# NAME                          READY   STATUS    RESTARTS   AGE
# postgresql-xxx                1/1     Running   0          1m

# Check databases were created
kubectl exec -n le-cicd deploy/postgresql -- psql -U linkedeye_admin -d postgres -c "\l"
# Should show: keycloak_db, harbor_core, harbor_notary_server, harbor_notary_signer, argocd_db, vault_db, jenkins_db
```

### Database Credentials

| Database | User | Password |
|---|---|---|
| Admin | linkedeye_admin | <DB_ADMIN_PASSWORD> |
| keycloak_db | keycloak_user | <DB_PASSWORD> |
| harbor_core | harbor_user | <DB_PASSWORD> |
| harbor_notary_server | harbor_user | <DB_PASSWORD> |
| harbor_notary_signer | harbor_user | <DB_PASSWORD> |
| argocd_db | argocd_user | <DB_PASSWORD> |
| vault_db | vault_user | <DB_PASSWORD> |
| jenkins_db | jenkins_user | <DB_PASSWORD> |

---

## 13. Phase 11 — Deploy Shared Tools

### 13.1 Jenkins

```bash
helm install jenkins jenkins/jenkins -n le-cicd -f manifests/jenkins/jenkins-values.yaml
```

Key settings:
- Admin: `admin / <TOOL_PASSWORD>`
- Persistence: 20Gi on local-path
- Plugins: kubernetes, workflow-aggregator, git, configuration-as-code, pipeline-stage-view, blueocean

> **Note:** Use `controller.admin.password` (NOT `controller.adminPassword` — deprecated in Jenkins Helm chart 2025+)

```bash
# Verify
kubectl get pods -n le-cicd -l app.kubernetes.io/name=jenkins
# NAME                READY   STATUS    AGE
# jenkins-0           2/2     Running   5m
```

### 13.2 ArgoCD

```bash
helm install argocd argo/argo-cd -n le-cicd -f manifests/argocd/argocd-values.yaml
```

Key settings:
- `configs.params.server.insecure: true` (TLS terminated at ALB/Ingress)
- Admin password is auto-generated

```bash
# Get ArgoCD admin password
kubectl -n le-cicd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# Result: <ARGOCD_PASSWORD>

# Verify
kubectl get pods -n le-cicd -l app.kubernetes.io/part-of=argocd
```

### 13.3 Harbor (Container Registry)

```bash
helm install harbor harbor/harbor -n le-cicd -f manifests/harbor/harbor-values.yaml
```

Key settings:
- `expose.type: clusterIP` (exposed via Ingress)
- External PostgreSQL (`postgresql.le-cicd.svc.cluster.local`)
- `externalURL: http://harbor.fs.le.finspot.in`
- Admin: `admin / <TOOL_PASSWORD>`
- Internal Redis
- Trivy scanner enabled

```bash
# Verify
kubectl get pods -n le-cicd -l app=harbor
```

> **Troubleshooting:** If Harbor StatefulSet update fails with "spec: Forbidden", do a full uninstall:
> ```bash
> helm uninstall harbor -n le-cicd
> kubectl delete pvc -n le-cicd -l app=harbor
> helm install harbor harbor/harbor -n le-cicd -f manifests/harbor/harbor-values.yaml
> ```

### 13.4 Keycloak (Identity & Access)

```bash
kubectl apply -f manifests/keycloak/keycloak-deployment.yaml
kubectl apply -f manifests/keycloak/keycloak-service.yaml
```

Key settings:
- Image: `quay.io/keycloak/keycloak:26.0` (official image, NOT bitnami)
- Start mode: `start-dev` (change to `start` for production with TLS)
- External PostgreSQL: `jdbc:postgresql://postgresql.le-cicd.svc.cluster.local:5432/keycloak_db`
- Hostname: `keycloak.fs.le.finspot.in`
- Admin: `admin / <TOOL_PASSWORD>`

> **Note:** Bitnami Keycloak images require subscription since Aug 2025. Use official quay.io image instead.

```bash
# Verify (87 tables created in keycloak_db)
kubectl get pods -n le-security -l app=keycloak
kubectl exec -n le-cicd deploy/postgresql -- psql -U keycloak_user -d keycloak_db -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
# count: 87
```

### 13.5 Vault (Secrets Management)

```bash
helm install vault hashicorp/vault -n le-security -f manifests/vault/vault-values.yaml
```

Key settings:
- **Standalone mode** (NOT HA — single worker node cannot run 3 replicas)
- Storage: file-based, 10Gi on local-path
- UI enabled
- Injector enabled

> **Note:** Initially deployed as HA (3 replicas) but vault-1/vault-2 stayed Pending since only 1 worker node. Switched to standalone.

```bash
# Verify
kubectl get pods -n le-security -l app.kubernetes.io/name=vault
# NAME      READY   STATUS    AGE
# vault-0   1/1     Running   5m
```

### 13.6 MinIO (S3-compatible Storage for Backups)

```bash
helm install minio minio/minio -n le-cicd -f manifests/minio/minio-values.yaml
```

Key settings:
- Standalone mode
- Root: `minioadmin / <TOOL_PASSWORD>`
- Persistence: 50Gi on local-path
- Used for database backup storage

```bash
# Verify
kubectl get pods -n le-cicd -l app=minio
```

---

## 14. Phase 12 — NGINX Ingress Controller

### Step 1: Install NGINX Ingress Controller

```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f manifests/ingress-nginx/nginx-ingress-values.yaml
```

Key settings:
- Service type: `NodePort`
- HTTP NodePort: `30080`
- HTTPS NodePort: `30443`
- proxy-body-size: 100m
- use-forwarded-headers: true (for ALB)

```bash
# Verify
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx
# NAME                             TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)
# ingress-nginx-controller         NodePort   172.20.x.x      <none>        80:30080/TCP,443:30443/TCP
```

### Step 2: Create Ingress Rules for All Tools

```bash
kubectl apply -f manifests/jenkins/jenkins-ingress.yaml
kubectl apply -f manifests/argocd/argocd-ingress.yaml
kubectl apply -f manifests/harbor/harbor-ingress.yaml
kubectl apply -f manifests/keycloak/keycloak-ingress.yaml
kubectl apply -f manifests/vault/vault-ingress.yaml
kubectl apply -f manifests/minio/minio-ingress.yaml
```

### Ingress Rules Summary

| Tool | Host | Backend Service | Port |
|---|---|---|---|
| Jenkins | jenkins.fs.le.finspot.in | jenkins:8080 | 8080 |
| ArgoCD | argocd.fs.le.finspot.in | argocd-server:80 | 80 |
| Harbor | harbor.fs.le.finspot.in | harbor:80 | 80 |
| Keycloak | keycloak.fs.le.finspot.in | keycloak:8080 | 8080 |
| Vault | vault.fs.le.finspot.in | vault-ui:8200 | 8200 |
| MinIO Console | minio.fs.le.finspot.in | minio-console:9001 | 9001 |
| MinIO API | s3.fs.le.finspot.in | minio:9000 | 9000 |

```bash
# Verify all ingress rules
kubectl get ingress -A
```

---

## 15. Phase 13 — AWS Application Load Balancer

### Step 1: Create Target Group

```bash
TG_ALB_ARN=$(aws elbv2 create-target-group \
  --name le-k8s-alb-tg \
  --protocol HTTP \
  --port 30080 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-path / \
  --health-check-protocol HTTP \
  --health-check-port 30080 \
  --tags Key=Project,Value=LinkedEye \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
```

### Step 2: Register Worker Node as Target

```bash
aws elbv2 register-targets \
  --target-group-arn $TG_ALB_ARN \
  --targets Id=$WORKER_ID,Port=30080
```

### Step 3: Create ALB

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name le-k8s-alb \
  --type application \
  --scheme internet-facing \
  --subnets $PUB_SUBNET $PUB_SUBNET_1B \
  --security-groups $SG_ALB \
  --tags Key=Project,Value=LinkedEye \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "ALB DNS: $ALB_DNS"
# Result: le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com
```

### Step 4: Create HTTP Listener (Port 80)

```bash
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=fixed-response,FixedResponseConfig='{StatusCode="404",ContentType="text/plain",MessageBody="LinkedEye - Not Found"}' \
  --query 'Listeners[0].ListenerArn' --output text)
```

### Step 5: Create Host-Based Routing Rules

```bash
# Jenkins
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 10 \
  --conditions Field=host-header,Values=jenkins.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN

# ArgoCD
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 20 \
  --conditions Field=host-header,Values=argocd.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN

# Harbor
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 30 \
  --conditions Field=host-header,Values=harbor.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN

# Keycloak
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 40 \
  --conditions Field=host-header,Values=keycloak.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN

# Vault
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 50 \
  --conditions Field=host-header,Values=vault.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN

# MinIO Console
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 60 \
  --conditions Field=host-header,Values=minio.fs.le.finspot.in \
  --actions Type=forward,TargetGroupArn=$TG_ALB_ARN
```

### Traffic Flow

```
Browser → DNS (finspot.in) → ALB (HTTP:80) → Host-based routing
  → Worker NodePort 30080 → NGINX Ingress Controller → K8s ClusterIP Service → Pod
```

---

## 16. Phase 14 — DNS Configuration (Cloudflare)

### Why Cloudflare

- **Free SSL/TLS** — No ACM certificate needed (solves IAM permission blocker)
- **DDoS protection** — Enterprise-grade protection included
- **CDN caching** — Faster global access
- **Proxy mode** — Hides origin server IPs

### Step 1: Add Domain to Cloudflare

1. Sign up / login at [dash.cloudflare.com](https://dash.cloudflare.com)
2. Click **"Add a Site"** → enter `finspot.in`
3. Select **Free plan** (sufficient for this setup)
4. Cloudflare provides 2 nameservers (e.g., `anna.ns.cloudflare.com`, `bob.ns.cloudflare.com`)

### Step 2: Update Nameservers in Hostinger

1. Login to Hostinger → Domains → `finspot.in` → DNS / Nameservers
2. Change nameservers from Hostinger to Cloudflare:
   - `anna.ns.cloudflare.com` (example — use actual values from Cloudflare)
   - `bob.ns.cloudflare.com`
3. Wait for propagation (can take up to 24 hours, usually 1-2 hours)

### Step 3: Add DNS Records in Cloudflare

Go to **DNS → Records** and add CNAME records:

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | jenkins.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | Proxied (orange cloud) |
| CNAME | argocd.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | Proxied (orange cloud) |
| CNAME | harbor.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | DNS Only (grey cloud) |
| CNAME | keycloak.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | Proxied (orange cloud) |
| CNAME | vault.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | Proxied (orange cloud) |
| CNAME | minio.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | Proxied (orange cloud) |
| CNAME | s3.fs.le | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com | DNS Only (grey cloud) |

> **Note:** Harbor and MinIO API (s3) should use **DNS Only** (grey cloud) to avoid Cloudflare interfering with Docker image push/pull and S3 API calls.

### Step 4: Configure SSL/TLS in Cloudflare

1. Go to **SSL/TLS → Overview**
2. Set encryption mode to **Flexible**
   - Browser → Cloudflare: **HTTPS** (encrypted)
   - Cloudflare → ALB: **HTTP** (port 80, since we don't have ACM cert)
3. Go to **SSL/TLS → Edge Certificates**
   - Enable **Always Use HTTPS** → ON
   - Enable **Automatic HTTPS Rewrites** → ON
   - Set **Minimum TLS Version** → TLS 1.2

### Step 5: Configure Security Settings

1. **Security → Settings:**
   - Security Level: **Medium**
   - Challenge Passage: **30 minutes**
2. **Security → WAF:**
   - Enable Managed Rules (free tier includes basic rules)

### Step 6: Caching Rules (Optional)

1. **Caching → Configuration:**
   - Caching Level: **Standard**
2. **Rules → Page Rules** (optional):
   - `*harbor.fs.le.finspot.in/*` → Cache Level: **Bypass** (don't cache Docker registry)
   - `*s3.fs.le.finspot.in/*` → Cache Level: **Bypass** (don't cache S3 API)

### Verify DNS & HTTPS

```bash
# Check DNS resolves through Cloudflare
nslookup jenkins.fs.le.finspot.in
# Should resolve to Cloudflare IPs (104.x.x.x or 172.x.x.x)

# Test HTTPS (provided by Cloudflare — no ACM needed!)
curl -s -o /dev/null -w "%{http_code}" https://jenkins.fs.le.finspot.in
# Should return 200 or 403

# Verify SSL certificate
curl -vI https://jenkins.fs.le.finspot.in 2>&1 | grep "issuer"
# Should show: issuer: Cloudflare Inc
```

### Traffic Flow with Cloudflare

```
Browser (HTTPS) → Cloudflare CDN/WAF (SSL termination)
  → ALB (HTTP:80) → Worker NodePort 30080
  → NGINX Ingress → K8s Service → Pod
```

### Access URLs (now HTTPS!)

| Tool | URL |
|---|---|
| Jenkins | https://jenkins.fs.le.finspot.in |
| ArgoCD | https://argocd.fs.le.finspot.in |
| Harbor | http://harbor.fs.le.finspot.in (DNS Only, no Cloudflare proxy) |
| Keycloak | https://keycloak.fs.le.finspot.in |
| Vault | https://vault.fs.le.finspot.in |
| MinIO | https://minio.fs.le.finspot.in |

---

## 17. Phase 15 — Vault Init & Unseal

### Step 1: Initialize Vault

```bash
kubectl exec -n le-security vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3
```

This outputs 5 unseal keys and 1 root token. **Save them securely.**

### Step 2: Unseal Vault (need 3 of 5 keys)

```bash
kubectl exec -n le-security vault-0 -- vault operator unseal <KEY-1>
kubectl exec -n le-security vault-0 -- vault operator unseal <KEY-2>
kubectl exec -n le-security vault-0 -- vault operator unseal <KEY-3>
```

### Step 3: Verify

```bash
kubectl exec -n le-security vault-0 -- vault status
# Sealed: false
# HA Enabled: false
```

### Unseal Keys (for this deployment)

```
Key 1: <UNSEAL_KEY_1>
Key 2: <UNSEAL_KEY_2>
Key 3: <UNSEAL_KEY_3>
Key 4: <UNSEAL_KEY_4>
Key 5: <UNSEAL_KEY_5>

Root Token: <VAULT_ROOT_TOKEN>
```

> **Important:** Vault must be unsealed after every pod restart. Use any 3 of the 5 keys.

---

## 18. Phase 16 — Database Backup (MinIO CronJob)

### Step 1: Deploy Backup CronJob

```bash
kubectl apply -f manifests/postgresql/postgresql-backup-cronjob.yaml
```

This creates:
- **CronJob:** Runs daily at 2:00 AM
- Backs up all databases (keycloak_db, harbor_core, argocd_db, vault_db, jenkins_db)
- Uploads dumps to MinIO bucket `le-db-backups`
- Full cluster dump via `pg_dumpall`
- Auto-deletes backups older than 7 days

### Step 2: Manual Backup (on-demand)

```bash
kubectl create job --from=cronjob/postgresql-backup manual-backup-$(date +%Y%m%d) -n le-cicd
```

### Step 3: Restore a Database

```bash
# List available backups
kubectl exec -n le-cicd deploy/postgresql -- bash -c "
  mc alias set leminio http://minio.le-cicd.svc.cluster.local:9000 minioadmin '<TOOL_PASSWORD>' --api S3v4
  mc ls --recursive leminio/le-db-backups/
"

# Restore specific database
# Example: restore keycloak_db from a specific dump file
kubectl exec -n le-cicd deploy/postgresql -- bash -c "
  mc alias set leminio http://minio.le-cicd.svc.cluster.local:9000 minioadmin '<TOOL_PASSWORD>' --api S3v4
  mc cp leminio/le-db-backups/keycloak_db/keycloak_db_20260307_020000.dump /tmp/restore.dump
  PGPASSWORD=<DB_ADMIN_PASSWORD> pg_restore -U linkedeye_admin -d keycloak_db /tmp/restore.dump
"
```

---

## 19. Current Status & Pending Items

### Completed

| # | Step | Status |
|---|---|---|
| 1 | VPC (10.100.0.0/16) | Done |
| 2 | Subnets (5 subnets) | Done |
| 3 | Internet Gateway | Done |
| 4 | NAT Gateway | Done |
| 5 | Route Tables (public + private) | Done |
| 6 | Security Groups (master, worker, ALB) | Done |
| 7 | EC2 Master (m5.2xlarge) | Done |
| 8 | EC2 Worker (m5.4xlarge) | Done |
| 9 | Elastic IPs (master + worker) | Done |
| 10 | Source/Dest Check Disabled | Done |
| 11 | Kubernetes Init (kubeadm v1.29) | Done |
| 12 | Calico CNI | Done |
| 13 | Worker Node Joined | Done |
| 14 | Namespaces (le-cicd, le-security, le-monitoring, ingress-nginx) | Done |
| 15 | Local-Path-Provisioner | Done |
| 16 | Helm v3 + Repos | Done |
| 17 | PostgreSQL (centralized, 7 databases) | Done |
| 18 | Jenkins | Done |
| 19 | ArgoCD | Done |
| 20 | Harbor (external PostgreSQL) | Done |
| 21 | Keycloak (external PostgreSQL) | Done |
| 22 | Vault (standalone, initialized, unsealed) | Done |
| 23 | MinIO (S3 backup storage) | Done |
| 24 | NGINX Ingress Controller (NodePort 30080) | Done |
| 25 | Ingress Rules (all 7 tools) | Done |
| 26 | ALB (HTTP host-based routing) | Done |
| 27 | DNS (Cloudflare → ALB) | Done |
| 28 | Manifest YAML files (all tools) | Done |

### Pending

| # | Item | Blocker |
|---|---|---|
| 1 | HTTPS/SSL (via Cloudflare) | Cloudflare free SSL — no ACM needed | Solved |
| 2 | Cloudflare DNS setup | Change nameservers in Hostinger → Cloudflare |
| 3 | IAM Roles (EC2 instance profiles) | No `iam:CreateRole` IAM permission |
| 4 | VPN (FortiGate on-prem → AWS) | Waiting for FortiGate public IP from Siva |
| 5 | PostgreSQL Backup CronJob deployment | Manifest ready, needs `kubectl apply` |
| 6 | Keycloak production mode (`start` vs `start-dev`) | Can proceed after Cloudflare HTTPS active |

---

## 20. Troubleshooting Reference

### Issue 1: Calico BGP Not Establishing

**Symptom:** calico-node pods `0/1 Running`, BIRD logs show "BGP not established"

**Fix:**
1. Disable source/dest check on EC2 instances
2. Add `protocol -1` SG rule within K8s subnet (10.100.10.0/24)
3. Delete calico-node pods to restart

### Issue 2: local-path-provisioner CrashLoopBackOff

**Symptom:** "dial tcp 172.20.0.1:443: i/o timeout"

**Fix:** Fix Calico networking first (Issue 1). Then:
```bash
kubectl rollout restart deploy -n local-path-storage local-path-provisioner
```

### Issue 3: Jenkins Helm Install Fails

**Symptom:** "`controller.adminPassword` no longer exists"

**Fix:** Use `controller.admin.password` instead:
```bash
helm install jenkins jenkins/jenkins -n le-cicd --set controller.admin.password=<TOOL_PASSWORD>
```

### Issue 4: Keycloak Bitnami Image Pull Error

**Symptom:** "docker.io/bitnami/keycloak: not found"

**Fix:** Use official image `quay.io/keycloak/keycloak:26.0` with custom Deployment manifest instead of Helm.

### Issue 5: Vault HA Pods Pending

**Symptom:** vault-1, vault-2 stuck in Pending (only 1 worker node)

**Fix:**
```bash
helm uninstall vault -n le-security
kubectl delete pvc -n le-security -l app.kubernetes.io/name=vault
# Reinstall with standalone mode
helm install vault hashicorp/vault -n le-security -f manifests/vault/vault-values.yaml
```

### Issue 6: Harbor StatefulSet Update Forbidden

**Symptom:** "cannot patch harbor-redis: spec: Forbidden"

**Fix:** Full uninstall + delete PVCs + reinstall:
```bash
helm uninstall harbor -n le-cicd
kubectl delete pvc -n le-cicd -l app=harbor
helm install harbor harbor/harbor -n le-cicd -f manifests/harbor/harbor-values.yaml
```

### Issue 7: Vault Sealed After Pod Restart

**Fix:** Unseal with any 3 of 5 keys:
```bash
kubectl exec -n le-security vault-0 -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n le-security vault-0 -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n le-security vault-0 -- vault operator unseal <UNSEAL_KEY_3>
```

---

## 21. All Credentials Reference

### Tool Access URLs

| Tool | URL | Username | Password |
|---|---|---|---|
| Jenkins | https://jenkins.fs.le.finspot.in | admin | <TOOL_PASSWORD> |
| ArgoCD | https://argocd.fs.le.finspot.in | admin | <ARGOCD_PASSWORD> |
| Harbor | http://harbor.fs.le.finspot.in (DNS Only) | admin | <TOOL_PASSWORD> |
| Keycloak | https://keycloak.fs.le.finspot.in | admin | <TOOL_PASSWORD> |
| Vault | https://vault.fs.le.finspot.in | Token | <VAULT_ROOT_TOKEN> |
| MinIO | https://minio.fs.le.finspot.in | minioadmin | <TOOL_PASSWORD> |

### SSH Access

```bash
# Master
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.105.154

# Worker
ssh -i ~/.ssh/le-shared-k8s-key.pem ubuntu@13.201.209.63
```

### AWS Resource IDs

| Resource | ID |
|---|---|
| VPC | vpc-0b902465605d6c6d6 |
| Public Subnet 1a | subnet-074f1da66fc7166fb |
| Public Subnet 1b | subnet-0b0e89de77a4c35a1 |
| K8s Subnet | subnet-065784ff2566bace7 |
| IGW | igw-03f7860ecc90aafd4 |
| NAT GW | nat-06401f68c43ff9511 |
| SG Master | sg-041ea1d03d124de1f |
| SG Worker | sg-0c49310672a092d83 |
| SG ALB | sg-0cad5f5884025ae0a |
| Master EC2 | i-0254e6bd512f67dd9 |
| Worker EC2 | i-0e0662a64aa8cc8e6 |
| Master EIP | 13.201.105.154 (eipalloc-0531ad74936699e09) |
| Worker EIP | 13.201.209.63 (eipalloc-0ca02fa0d27fba4f1) |
| ALB | le-k8s-alb-1670364191.ap-south-1.elb.amazonaws.com |
| Target Group | arn:aws:elasticloadbalancing:ap-south-1:654697417727:targetgroup/le-k8s-alb-tg/ade449a2551b6221 |

### Manifest Files Location

```
manifests/
├── namespaces/
│   └── namespaces.yaml
├── postgresql/
│   ├── postgresql-deployment.yaml    (Secret + ConfigMap + PVC + Deployment + Service)
│   └── postgresql-backup-cronjob.yaml (CronJob + backup/restore scripts)
├── jenkins/
│   ├── jenkins-values.yaml           (Helm values)
│   └── jenkins-ingress.yaml          (Ingress rule)
├── argocd/
│   ├── argocd-values.yaml            (Helm values)
│   └── argocd-ingress.yaml           (Ingress rule)
├── harbor/
│   ├── harbor-values.yaml            (Helm values with external PostgreSQL)
│   └── harbor-ingress.yaml           (Ingress rule)
├── keycloak/
│   ├── keycloak-deployment.yaml      (Secret + Deployment)
│   ├── keycloak-service.yaml         (ClusterIP Service)
│   ├── keycloak-secret.yaml          (Standalone Secret)
│   └── keycloak-ingress.yaml         (Ingress rule)
├── vault/
│   ├── vault-values.yaml             (Helm values, standalone mode)
│   └── vault-ingress.yaml            (Ingress rule)
├── minio/
│   ├── minio-values.yaml             (Helm values)
│   └── minio-ingress.yaml            (Console + API Ingress)
└── ingress-nginx/
    └── nginx-ingress-values.yaml     (Helm values, NodePort 30080/30443)
```

### Contacts

| Role | Name | Phone |
|---|---|---|
| CTO / DevOps | Rajkumar Madhu | +91-917-677-2077 |
| Ops Lead | Hoysala Bise | +91-998-014-6101 |
| Network Lead (VPN/FW) | Siva Kadirannagari | +91-960-368-3828 |
| DBA | Rajkumar Ashokan | +91-975-189-2775 |

---

*Document generated: 2026-03-07*
*Platform: LinkedEye Shared ITSM/Monitoring*
*Organization: FinSpot Technology Solutions*
