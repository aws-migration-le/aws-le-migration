#!/usr/bin/env bash
# ============================================================
# PHASE 2 — IAM Roles for EC2 Instances (K8s nodes)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " IAM Setup — EC2 Instance Profiles for K8s Nodes"
echo "============================================================"

# ─── TRUST POLICY ────────────────────────────────────────────
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

# ─── K8s MASTER ROLE ─────────────────────────────────────────
echo "[IAM-1] Creating K8s Master IAM role"
aws iam create-role \
  --role-name "${PROJECT}-k8s-master-role" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "LinkedEye K8s Master - EFS, ECR, SSM access" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV}

# Attach managed policies
aws iam attach-role-policy \
  --role-name "${PROJECT}-k8s-master-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

aws iam attach-role-policy \
  --role-name "${PROJECT}-k8s-master-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam attach-role-policy \
  --role-name "${PROJECT}-k8s-master-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# ─── INLINE POLICY: EFS Access ───────────────────────────────
aws iam put-role-policy \
  --role-name "${PROJECT}-k8s-master-role" \
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

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name "${PROJECT}-k8s-master-profile" \
  --tags Key=Project,Value=${TAG_PROJECT}
aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROJECT}-k8s-master-profile" \
  --role-name "${PROJECT}-k8s-master-role"

echo "    Master role created: ${PROJECT}-k8s-master-role"

# ─── K8s WORKER ROLE ─────────────────────────────────────────
echo "[IAM-2] Creating K8s Worker IAM role"
aws iam create-role \
  --role-name "${PROJECT}-k8s-worker-role" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "LinkedEye K8s Workers - ECR, EFS, SSM" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV}

aws iam attach-role-policy \
  --role-name "${PROJECT}-k8s-worker-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy \
  --role-name "${PROJECT}-k8s-worker-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam put-role-policy \
  --role-name "${PROJECT}-k8s-worker-role" \
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

aws iam create-instance-profile \
  --instance-profile-name "${PROJECT}-k8s-worker-profile" \
  --tags Key=Project,Value=${TAG_PROJECT}
aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROJECT}-k8s-worker-profile" \
  --role-name "${PROJECT}-k8s-worker-role"

echo "    Worker role created: ${PROJECT}-k8s-worker-role"

# ─── BASTION ROLE ────────────────────────────────────────────
echo "[IAM-3] Creating Bastion IAM role"
aws iam create-role \
  --role-name "${PROJECT}-bastion-role" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "LinkedEye Bastion - SSM session manager" \
  --tags Key=Project,Value=${TAG_PROJECT}

aws iam attach-role-policy \
  --role-name "${PROJECT}-bastion-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile \
  --instance-profile-name "${PROJECT}-bastion-profile" \
  --tags Key=Project,Value=${TAG_PROJECT}
aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROJECT}-bastion-profile" \
  --role-name "${PROJECT}-bastion-role"

echo ""
echo "[DONE] IAM roles and instance profiles created"
echo "  Master profile: ${PROJECT}-k8s-master-profile"
echo "  Worker profile: ${PROJECT}-k8s-worker-profile"
echo "  Bastion profile: ${PROJECT}-bastion-profile"
