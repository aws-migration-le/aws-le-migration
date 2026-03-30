#!/usr/bin/env bash
# ============================================================
# PHASE 1 — STEP 2: NAT Gateways (HA — one per AZ)
# Prereq: Run 01-create-vpc.sh first
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " NAT Gateway Setup (HA across 2 AZs)"
echo "============================================================"

# ─── ELASTIC IPs ─────────────────────────────────────────────
echo "[2.1] Allocating Elastic IPs for NAT Gateways"
EIP1=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[
    {Key=Name,Value=${PROJECT}-nat-eip-az1},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'AllocationId' --output text)

EIP2=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[
    {Key=Name,Value=${PROJECT}-nat-eip-az2},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'AllocationId' --output text)

echo "    EIP1: ${EIP1}"
echo "    EIP2: ${EIP2}"

# ─── NAT GATEWAYS ────────────────────────────────────────────
echo "[2.2] Creating NAT Gateway in AZ1 (primary)"
NAT_GW_AZ1=$(aws ec2 create-nat-gateway \
  --subnet-id "${PUB_SUBNET_AZ1}" --allocation-id "${EIP1}" \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=${PROJECT}-nat-az1},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'NatGateway.NatGatewayId' --output text)

echo "[2.3] Creating NAT Gateway in AZ2 (HA standby)"
NAT_GW_AZ2=$(aws ec2 create-nat-gateway \
  --subnet-id "${PUB_SUBNET_AZ2}" --allocation-id "${EIP2}" \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=${PROJECT}-nat-az2},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'NatGateway.NatGatewayId' --output text)

echo "    Waiting for NAT Gateways to become available (~60s)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_AZ1}"
aws ec2 wait nat-gateway-available --nat-gateway-ids "${NAT_GW_AZ2}"
echo "    Both NAT Gateways are available"

# ─── PRIVATE ROUTE TABLES ────────────────────────────────────
echo "[2.4] Private route table AZ1 → NAT-AZ1"
PRIV_RTB_AZ1=$(aws ec2 create-route-table \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=${PROJECT}-private-rtb-az1},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "${PRIV_RTB_AZ1}" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW_AZ1}"
aws ec2 associate-route-table --route-table-id "${PRIV_RTB_AZ1}" --subnet-id "${PRIV_SUBNET_AZ1}"
aws ec2 associate-route-table --route-table-id "${PRIV_RTB_AZ1}" --subnet-id "${STORAGE_SUBNET_AZ1}"

echo "[2.5] Private route table AZ2 → NAT-AZ2"
PRIV_RTB_AZ2=$(aws ec2 create-route-table \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=${PROJECT}-private-rtb-az2},{Key=Project,Value=${TAG_PROJECT}}
  ]" --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id "${PRIV_RTB_AZ2}" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW_AZ2}"
aws ec2 associate-route-table --route-table-id "${PRIV_RTB_AZ2}" --subnet-id "${PRIV_SUBNET_AZ2}"
aws ec2 associate-route-table --route-table-id "${PRIV_RTB_AZ2}" --subnet-id "${STORAGE_SUBNET_AZ2}"

# ─── PERSIST ─────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export NAT_GW_AZ1="${NAT_GW_AZ1}"
export NAT_GW_AZ2="${NAT_GW_AZ2}"
export PRIV_RTB_AZ1="${PRIV_RTB_AZ1}"
export PRIV_RTB_AZ2="${PRIV_RTB_AZ2}"
export EIP1="${EIP1}"
export EIP2="${EIP2}"
EOF

echo ""
echo "[DONE] NAT Gateways ready (HA)"
echo "  NAT-AZ1: ${NAT_GW_AZ1}"
echo "  NAT-AZ2: ${NAT_GW_AZ2}"
