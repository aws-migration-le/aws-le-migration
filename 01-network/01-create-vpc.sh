#!/usr/bin/env bash
# ============================================================
# PHASE 1 — STEP 1: Create VPC, Subnets, Internet Gateway
# Run: bash 01-network/01-create-vpc.sh
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

STATE_FILE="/tmp/le-network-ids.env"

echo "============================================================"
echo " LinkedEye VPC Setup — Region: ${AWS_REGION}"
echo "============================================================"

# ─── VPC ─────────────────────────────────────────────────────
echo "[1.1] Creating VPC CIDR=${VPC_CIDR}"
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "${VPC_CIDR}" \
  --region "${AWS_REGION}" \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=${PROJECT}-shared-vpc},
    {Key=Project,Value=${TAG_PROJECT}},
    {Key=Environment,Value=${TAG_ENV}},
    {Key=Owner,Value=${TAG_OWNER}}
  ]" \
  --query 'Vpc.VpcId' --output text)
echo "    VPC: ${VPC_ID}"

aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
echo "    DNS hostnames + support enabled"

# ─── PUBLIC SUBNETS ──────────────────────────────────────────
echo "[1.2] Creating public subnet AZ1 (${PUBLIC_SUBNET_AZ1_CIDR})"
PUB_SUBNET_AZ1=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${PUBLIC_SUBNET_AZ1_CIDR}" \
  --availability-zone "${AZ1}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-public-az1},
    {Key=Tier,Value=Public},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "${PUB_SUBNET_AZ1}" --map-public-ip-on-launch

echo "[1.3] Creating public subnet AZ2 (${PUBLIC_SUBNET_AZ2_CIDR})"
PUB_SUBNET_AZ2=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${PUBLIC_SUBNET_AZ2_CIDR}" \
  --availability-zone "${AZ2}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-public-az2},
    {Key=Tier,Value=Public},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "${PUB_SUBNET_AZ2}" --map-public-ip-on-launch

# ─── PRIVATE SUBNETS ─────────────────────────────────────────
echo "[1.4] Creating private subnet AZ1 (${PRIVATE_SUBNET_AZ1_CIDR})"
PRIV_SUBNET_AZ1=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${PRIVATE_SUBNET_AZ1_CIDR}" \
  --availability-zone "${AZ1}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-private-az1},
    {Key=Tier,Value=Private},
    {Key=kubernetes.io/role/internal-elb,Value=1},
    {Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)

echo "[1.5] Creating private subnet AZ2 (${PRIVATE_SUBNET_AZ2_CIDR})"
PRIV_SUBNET_AZ2=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${PRIVATE_SUBNET_AZ2_CIDR}" \
  --availability-zone "${AZ2}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-private-az2},
    {Key=Tier,Value=Private},
    {Key=kubernetes.io/role/internal-elb,Value=1},
    {Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)

# ─── STORAGE SUBNETS ─────────────────────────────────────────
echo "[1.6] Creating storage subnets (EFS)"
STORAGE_SUBNET_AZ1=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${STORAGE_SUBNET_AZ1_CIDR}" \
  --availability-zone "${AZ1}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-storage-az1},
    {Key=Tier,Value=Storage},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)

STORAGE_SUBNET_AZ2=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${STORAGE_SUBNET_AZ2_CIDR}" \
  --availability-zone "${AZ2}" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-storage-az2},
    {Key=Tier,Value=Storage},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'Subnet.SubnetId' --output text)

# ─── INTERNET GATEWAY ────────────────────────────────────────
echo "[1.7] Creating Internet Gateway"
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[
    {Key=Name,Value=${PROJECT}-igw},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"
echo "    IGW ${IGW_ID} attached"

# ─── PUBLIC ROUTE TABLE ──────────────────────────────────────
echo "[1.8] Creating public route table (0.0.0.0/0 → IGW)"
PUB_RTB=$(aws ec2 create-route-table \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=${PROJECT}-public-rtb},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "${PUB_RTB}" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}"

aws ec2 associate-route-table --route-table-id "${PUB_RTB}" --subnet-id "${PUB_SUBNET_AZ1}"
aws ec2 associate-route-table --route-table-id "${PUB_RTB}" --subnet-id "${PUB_SUBNET_AZ2}"

# ─── PERSIST IDs ─────────────────────────────────────────────
cat > "${STATE_FILE}" <<EOF
export VPC_ID="${VPC_ID}"
export PUB_SUBNET_AZ1="${PUB_SUBNET_AZ1}"
export PUB_SUBNET_AZ2="${PUB_SUBNET_AZ2}"
export PRIV_SUBNET_AZ1="${PRIV_SUBNET_AZ1}"
export PRIV_SUBNET_AZ2="${PRIV_SUBNET_AZ2}"
export STORAGE_SUBNET_AZ1="${STORAGE_SUBNET_AZ1}"
export STORAGE_SUBNET_AZ2="${STORAGE_SUBNET_AZ2}"
export IGW_ID="${IGW_ID}"
export PUB_RTB="${PUB_RTB}"
EOF

echo ""
echo "============================================================"
echo " [DONE] VPC Setup Complete"
echo "  VPC:             ${VPC_ID}"
echo "  Public AZ1:      ${PUB_SUBNET_AZ1}"
echo "  Public AZ2:      ${PUB_SUBNET_AZ2}"
echo "  Private AZ1:     ${PRIV_SUBNET_AZ1}"
echo "  Private AZ2:     ${PRIV_SUBNET_AZ2}"
echo "  IGW:             ${IGW_ID}"
echo "  IDs saved to:    ${STATE_FILE}"
echo "============================================================"
