#!/usr/bin/env bash
# ============================================================
# PHASE 2 — STEP 3: Management EC2 IAM Role + Instance Profile
# Single role shared by Jenkins (EC2-A), Mgmt (EC2-B), ITSM (EC2-C)
# Grants: SSM, ECR pull, EKS access, EFS mount, CloudWatch logs
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Management EC2 IAM Role + Instance Profile"
echo "============================================================"

# ─── TRUST POLICY ───────────────────────────────────────────
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

echo "[IAM-MGMT-1] Creating management EC2 IAM role"
aws iam create-role \
  --role-name "${PROJECT}-mgmt-ec2-role" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "LinkedEye Mgmt EC2s - SSM, ECR, EKS, EFS, CloudWatch" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV}

# SSM for remote management
aws iam attach-role-policy \
  --role-name "${PROJECT}-mgmt-ec2-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# ECR read for pulling container images
aws iam attach-role-policy \
  --role-name "${PROJECT}-mgmt-ec2-role" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# EKS describe-cluster for kubeconfig
aws iam put-role-policy \
  --role-name "${PROJECT}-mgmt-ec2-role" \
  --policy-name "EKS-Access" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["eks:DescribeCluster",
                 "eks:ListClusters"],
      "Resource": "*"
    }]
  }'

# EFS access for shared storage
aws iam put-role-policy \
  --role-name "${PROJECT}-mgmt-ec2-role" \
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

# CloudWatch Logs for container log shipping
aws iam put-role-policy \
  --role-name "${PROJECT}-mgmt-ec2-role" \
  --policy-name "CloudWatch-Logs" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup",
                 "logs:CreateLogStream",
                 "logs:PutLogEvents",
                 "logs:DescribeLogGroups"],
      "Resource": "arn:aws:logs:'"${AWS_REGION}"':'"${AWS_ACCOUNT_ID}"':*"
    }]
  }'

echo "    Role created: ${PROJECT}-mgmt-ec2-role"

# ─── INSTANCE PROFILE ──────────────────────────────────────
echo "[IAM-MGMT-2] Creating instance profile"
aws iam create-instance-profile \
  --instance-profile-name "${PROJECT}-mgmt-ec2-profile" \
  --tags Key=Project,Value=${TAG_PROJECT}

aws iam add-role-to-instance-profile \
  --instance-profile-name "${PROJECT}-mgmt-ec2-profile" \
  --role-name "${PROJECT}-mgmt-ec2-role"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export MGMT_EC2_ROLE="${PROJECT}-mgmt-ec2-role"
export MGMT_EC2_PROFILE="${PROJECT}-mgmt-ec2-profile"
EOF

echo ""
echo "[DONE] Management EC2 IAM setup complete"
echo "  Role:     ${PROJECT}-mgmt-ec2-role"
echo "  Profile:  ${PROJECT}-mgmt-ec2-profile"
echo ""
echo "  NOTE: Wait ~10 seconds for IAM propagation before launching EC2s"
