#!/usr/bin/env bash
# ============================================================
# PHASE 1 — STEP 3: Security Groups (Firewall Rules)
# Prereq: Run 01 and 02 first
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Security Groups Setup (Firewall Rules)"
echo "============================================================"

# ─── BASTION HOST SG ─────────────────────────────────────────
echo "[3.1] Bastion Host SG (SSH from on-prem only)"
SG_BASTION=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-bastion-sg" \
  --description "LinkedEye Bastion - SSH jump host" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-bastion-sg},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'GroupId' --output text)

# SSH from on-prem LAN only
aws ec2 authorize-security-group-ingress --group-id "${SG_BASTION}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":22,"ToPort":22,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem SSH"}]}
  ]'
echo "    SG_BASTION: ${SG_BASTION}"

# ─── K8s MASTER SG ───────────────────────────────────────────
echo "[3.2] K8s Master Node SG"
SG_K8S_MASTER=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-k8s-master-sg" \
  --description "LinkedEye K8s Master - API server + etcd" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-k8s-master-sg},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_K8S_MASTER}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":22,"ToPort":22,
     "IpRanges":[{"CidrIp":"10.15.1.0/24","Description":"Bastion subnet SSH"}]},
    {"IpProtocol":"tcp","FromPort":6443,"ToPort":6443,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"K8s API - internal"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem kubectl"}]},
    {"IpProtocol":"tcp","FromPort":2379,"ToPort":2380,
     "IpRanges":[{"CidrIp":"10.15.10.0/24","Description":"etcd cluster"},
                 {"CidrIp":"10.15.11.0/24","Description":"etcd cluster AZ2"}]},
    {"IpProtocol":"tcp","FromPort":10250,"ToPort":10259,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"kubelet/scheduler/controller"}]},
    {"IpProtocol":"tcp","FromPort":179,"ToPort":179,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Calico BGP"}]},
    {"IpProtocol":"4","FromPort":-1,"ToPort":-1,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Calico IPIP"}]}
  ]'
echo "    SG_K8S_MASTER: ${SG_K8S_MASTER}"

# ─── K8s WORKER SG ───────────────────────────────────────────
echo "[3.3] K8s Worker Nodes SG"
SG_K8S_WORKER=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-k8s-worker-sg" \
  --description "LinkedEye K8s Workers - workload nodes" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-k8s-worker-sg},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_K8S_WORKER}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":22,"ToPort":22,
     "IpRanges":[{"CidrIp":"10.15.1.0/24","Description":"Bastion SSH"}]},
    {"IpProtocol":"tcp","FromPort":10250,"ToPort":10250,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"kubelet"}]},
    {"IpProtocol":"tcp","FromPort":30000,"ToPort":32767,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"NodePort services"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem NodePort"}]},
    {"IpProtocol":"tcp","FromPort":179,"ToPort":179,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Calico BGP"}]},
    {"IpProtocol":"4","FromPort":-1,"ToPort":-1,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Calico IPIP"}]},
    {"IpProtocol":"tcp","FromPort":8472,"ToPort":8472,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Flannel VXLAN (if used)"}]},
    {"IpProtocol":"udp","FromPort":8472,"ToPort":8472,
     "IpRanges":[{"CidrIp":"10.15.0.0/16","Description":"Flannel VXLAN UDP"}]}
  ]'
echo "    SG_K8S_WORKER: ${SG_K8S_WORKER}"

# ─── NLB / INGRESS SG ────────────────────────────────────────
echo "[3.4] Network Load Balancer / Ingress SG"
SG_NLB=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-nlb-sg" \
  --description "LinkedEye NLB - public HTTPS ingress" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-nlb-sg},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_NLB}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":80,"ToPort":80,
     "IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTP redirect"}]},
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS ingress"}]}
  ]'
echo "    SG_NLB: ${SG_NLB}"

# ─── EFS SG ──────────────────────────────────────────────────
echo "[3.5] EFS (NFS) Storage SG"
SG_EFS=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-efs-sg" \
  --description "LinkedEye EFS - NFS from K8s nodes" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-efs-sg},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_EFS}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":2049,"ToPort":2049,
     "IpRanges":[{"CidrIp":"10.15.10.0/24","Description":"K8s nodes AZ1 NFS"},
                 {"CidrIp":"10.15.11.0/24","Description":"K8s nodes AZ2 NFS"}]}
  ]'
echo "    SG_EFS: ${SG_EFS}"

# ─── PERSIST ─────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export SG_BASTION="${SG_BASTION}"
export SG_K8S_MASTER="${SG_K8S_MASTER}"
export SG_K8S_WORKER="${SG_K8S_WORKER}"
export SG_NLB="${SG_NLB}"
export SG_EFS="${SG_EFS}"
EOF

echo ""
echo "[DONE] All Security Groups created"
echo "  Bastion:    ${SG_BASTION}"
echo "  K8s Master: ${SG_K8S_MASTER}"
echo "  K8s Worker: ${SG_K8S_WORKER}"
echo "  NLB:        ${SG_NLB}"
echo "  EFS:        ${SG_EFS}"
