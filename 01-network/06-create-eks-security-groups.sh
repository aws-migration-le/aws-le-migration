#!/usr/bin/env bash
# ============================================================
# PHASE 1 — STEP 6: Security Groups for EKS + Management EC2s
# Creates: SG_EKS_CLUSTER, SG_EKS_HYBRID, SG_JENKINS_EC2,
#          SG_MGMT_EC2, SG_ALB
# EC2s run in PUBLIC subnet (no bastion).
# EKS uses Hybrid Nodes (workers on-prem per client).
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Security Groups for EKS Hybrid + Management EC2s"
echo "============================================================"

# ─── ALB SG ─────────────────────────────────────────────────
echo "[6.1] ALB Security Group (public HTTPS)"
SG_ALB=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-alb-sg" \
  --description "LinkedEye ALB - public HTTPS for tools" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-alb-sg},{Key=Project,Value=${TAG_PROJECT}},{Key=Environment,Value=${TAG_ENV}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_ALB}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":80,"ToPort":80,
     "IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTP redirect"}]},
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS ingress"}]}
  ]'
echo "    SG_ALB: ${SG_ALB}"

# ─── EKS CLUSTER SG ────────────────────────────────────────
echo "[6.2] EKS Cluster (Control Plane) SG"
SG_EKS_CLUSTER=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-eks-cluster-sg" \
  --description "LinkedEye EKS Control Plane - API access" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-eks-cluster-sg},{Key=Project,Value=${TAG_PROJECT}},{Key=Environment,Value=${TAG_ENV}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_EKS_CLUSTER}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "IpRanges":[{"CidrIp":"10.100.0.0/16","Description":"VPC internal kubectl"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem hybrid nodes API access"}]}
  ]'
echo "    SG_EKS_CLUSTER: ${SG_EKS_CLUSTER}"

# ─── EKS HYBRID NODES SG (on-prem traffic via VPN) ─────────
echo "[6.3] EKS Hybrid Nodes SG (on-prem workers via VPN)"
SG_EKS_HYBRID=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-eks-hybrid-sg" \
  --description "LinkedEye EKS Hybrid Node traffic via VPN" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-eks-hybrid-sg},{Key=Project,Value=${TAG_PROJECT}},{Key=Environment,Value=${TAG_ENV}}
  ]" --query 'GroupId' --output text)

# Allow hybrid node traffic from on-prem CIDRs through VPN
aws ec2 authorize-security-group-ingress --group-id "${SG_EKS_HYBRID}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"Hybrid node kubelet HTTPS"}]},
    {"IpProtocol":"tcp","FromPort":10250,"ToPort":10250,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"Hybrid node kubelet"}]},
    {"IpProtocol":"tcp","FromPort":4789,"ToPort":4789,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"VXLAN overlay (Cilium)"}]},
    {"IpProtocol":"udp","FromPort":4789,"ToPort":4789,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"VXLAN overlay UDP"}]}
  ]'

# Allow EKS cluster → hybrid nodes
aws ec2 authorize-security-group-ingress --group-id "${SG_EKS_CLUSTER}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_EKS_HYBRID}"'","Description":"Hybrid nodes to API"}]}
  ]'
echo "    SG_EKS_HYBRID: ${SG_EKS_HYBRID}"

# ─── JENKINS EC2 SG (PUBLIC SUBNET) ────────────────────────
echo "[6.4] Jenkins EC2 SG (EC2-A, public subnet)"
SG_JENKINS_EC2=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-jenkins-ec2-sg" \
  --description "LinkedEye Jenkins EC2 - CI/CD builds (public)" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-jenkins-ec2-sg},{Key=Project,Value=${TAG_PROJECT}},{Key=Environment,Value=${TAG_ENV}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_JENKINS_EC2}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":22,"ToPort":22,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"SSH from office"}]},
    {"IpProtocol":"tcp","FromPort":8080,"ToPort":8080,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB Jenkins UI"}]},
    {"IpProtocol":"tcp","FromPort":8080,"ToPort":8080,
     "IpRanges":[{"CidrIp":"10.100.0.0/16","Description":"Internal Jenkins access"}]},
    {"IpProtocol":"tcp","FromPort":50000,"ToPort":50000,
     "IpRanges":[{"CidrIp":"10.100.0.0/16","Description":"Jenkins agent JNLP"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem Jenkins agents"}]}
  ]'
echo "    SG_JENKINS_EC2: ${SG_JENKINS_EC2}"

# ─── MANAGEMENT + ITSM EC2 SG (PUBLIC SUBNET) ──────────────
echo "[6.5] Management+ITSM EC2 SG (EC2-B, public subnet)"
echo "      Harbor, ArgoCD, Keycloak, Vault, PostgreSQL, ITSM"
SG_MGMT_EC2=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-mgmt-ec2-sg" \
  --description "LinkedEye Mgmt+ITSM EC2 - all management tools" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-mgmt-ec2-sg},{Key=Project,Value=${TAG_PROJECT}},{Key=Environment,Value=${TAG_ENV}}
  ]" --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "${SG_MGMT_EC2}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":22,"ToPort":22,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"SSH from office"}]},
    {"IpProtocol":"tcp","FromPort":5000,"ToPort":5000,
     "IpRanges":[{"CidrIp":"10.100.0.0/16","Description":"Harbor registry (Docker)"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem Harbor pull"}]},
    {"IpProtocol":"tcp","FromPort":8081,"ToPort":8081,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB Keycloak"}]},
    {"IpProtocol":"tcp","FromPort":8082,"ToPort":8082,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB ArgoCD"}]},
    {"IpProtocol":"tcp","FromPort":8083,"ToPort":8083,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB Harbor UI"}]},
    {"IpProtocol":"tcp","FromPort":8200,"ToPort":8200,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB Vault"}]},
    {"IpProtocol":"tcp","FromPort":8200,"ToPort":8200,
     "IpRanges":[{"CidrIp":"10.100.0.0/16","Description":"Vault internal VPC"},
                 {"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem Vault access"}]},
    {"IpProtocol":"tcp","FromPort":80,"ToPort":80,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB ITSM HTTP"}]},
    {"IpProtocol":"tcp","FromPort":443,"ToPort":443,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_ALB}"'","Description":"ALB ITSM HTTPS"}]},
    {"IpProtocol":"tcp","FromPort":5432,"ToPort":5432,
     "UserIdGroupPairs":[{"GroupId":"'"${SG_MGMT_EC2}"'","Description":"PostgreSQL internal"}]}
  ]'
echo "    SG_MGMT_EC2: ${SG_MGMT_EC2}"

# ─── UPDATE EFS SG — allow on-prem hybrid nodes ─────────────
echo "[6.6] Updating EFS SG — adding on-prem CIDR for hybrid nodes"
aws ec2 authorize-security-group-ingress --group-id "${SG_EFS}" \
  --ip-permissions '[
    {"IpProtocol":"tcp","FromPort":2049,"ToPort":2049,
     "IpRanges":[{"CidrIp":"'"${ONPREM_CIDR}"'","Description":"On-prem hybrid nodes NFS"}]}
  ]' 2>/dev/null || echo "    (rule may already exist)"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export SG_ALB="${SG_ALB}"
export SG_EKS_CLUSTER="${SG_EKS_CLUSTER}"
export SG_EKS_HYBRID="${SG_EKS_HYBRID}"
export SG_JENKINS_EC2="${SG_JENKINS_EC2}"
export SG_MGMT_EC2="${SG_MGMT_EC2}"
EOF

echo ""
echo "[DONE] All Security Groups created"
echo "  ALB:          ${SG_ALB}"
echo "  EKS Cluster:  ${SG_EKS_CLUSTER}"
echo "  EKS Hybrid:   ${SG_EKS_HYBRID}"
echo "  Jenkins EC2:  ${SG_JENKINS_EC2}"
echo "  Mgmt+ITSM:    ${SG_MGMT_EC2}"
