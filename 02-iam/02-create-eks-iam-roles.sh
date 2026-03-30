#!/usr/bin/env bash
# ============================================================
# PHASE 2 — STEP 2: EKS IAM Roles
# Creates: linkedeye-eks-cluster-role (for EKS control plane)
#          linkedeye-eks-nodegroup-role (for managed node group)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " EKS IAM Roles — Cluster + Node Group"
echo "============================================================"

# ─── EKS CLUSTER ROLE ──────────────────────────────────────
echo "[IAM-EKS-1] Creating EKS Cluster IAM role"
EKS_CLUSTER_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "eks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name "${PROJECT}-eks-cluster-role" \
  --assume-role-policy-document "${EKS_CLUSTER_TRUST}" \
  --description "LinkedEye EKS Cluster - control plane role" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV}

aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-cluster-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-cluster-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSVPCResourceController

echo "    EKS cluster role: ${PROJECT}-eks-cluster-role"

# ─── EKS NODE GROUP ROLE ───────────────────────────────────
echo "[IAM-EKS-2] Creating EKS Node Group IAM role"
EKS_NODE_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --assume-role-policy-document "${EKS_NODE_TRUST}" \
  --description "LinkedEye EKS Node Group - worker nodes" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV}

# Required managed policies for EKS worker nodes
aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# EFS access for persistent volumes
aws iam put-role-policy \
  --role-name "${PROJECT}-eks-nodegroup-role" \
  --policy-name "EFS-Access" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["elasticfilesystem:DescribeFileSystems",
                 "elasticfilesystem:DescribeMountTargets",
                 "elasticfilesystem:ClientMount",
                 "elasticfilesystem:ClientWrite"],
      "Resource": "*"
    }]
  }'

echo "    EKS node group role: ${PROJECT}-eks-nodegroup-role"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export EKS_CLUSTER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-eks-cluster-role"
export EKS_NODEGROUP_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-eks-nodegroup-role"
EOF

echo ""
echo "[DONE] EKS IAM roles created"
echo "  Cluster role ARN:   arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-eks-cluster-role"
echo "  Node group role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-eks-nodegroup-role"
