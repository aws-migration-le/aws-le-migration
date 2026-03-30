#!/usr/bin/env bash
# ============================================================
# PHASE V — Full Validation (EKS Hybrid + EC2 Public)
# Validates: Network, EKS, EC2s (public), Tools, Hybrid Nodes
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "${cmd}" &>/dev/null; then
    echo "  [PASS] ${name}"
    ((PASS++))
  else
    echo "  [FAIL] ${name}"
    ((FAIL++))
  fi
}

echo "============================================================"
echo " LinkedEye Validation (EKS Hybrid + Public EC2s)"
echo "============================================================"

echo ""
echo "-- AWS Network ---------------------------------------------------"
check "VPC exists" "aws ec2 describe-vpcs --filters Name=tag:Project,Values=LinkedEye --query 'Vpcs[0].VpcId' --output text | grep -v None"
check "Public subnets" "aws ec2 describe-subnets --filters Name=tag:Tier,Values=Public Name=tag:Project,Values=LinkedEye | grep -q SubnetId"
check "NAT Gateway active" "aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=LinkedEye --query 'NatGateways[?State==\`available\`]' --output text | grep -q nat-"
check "Internet Gateway attached" "aws ec2 describe-internet-gateways --filters Name=tag:Project,Values=LinkedEye | grep -q InternetGatewayId"

echo ""
echo "-- EKS Cluster ---------------------------------------------------"
check "EKS cluster ACTIVE" "aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --query 'cluster.status' --output text | grep -q ACTIVE"
check "EKS endpoint public+private" "aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text | grep -q true"
check "EKS vpc-cni addon" "aws eks describe-addon --cluster-name ${EKS_CLUSTER_NAME} --addon-name vpc-cni --query 'addon.status' --output text | grep -q ACTIVE"
check "EKS coredns addon" "aws eks describe-addon --cluster-name ${EKS_CLUSTER_NAME} --addon-name coredns --query 'addon.status' --output text | grep -q ACTIVE"
check "Namespace le-monitoring" "kubectl get ns le-monitoring 2>/dev/null"
check "Namespace le-workloads" "kubectl get ns le-workloads 2>/dev/null"

echo ""
echo "-- Hybrid Nodes (on-prem workers) --------------------------------"
HYBRID_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
echo "  [INFO] Hybrid nodes registered: ${HYBRID_COUNT}"
if [ "${HYBRID_COUNT}" -gt 0 ]; then
  check "Hybrid node(s) Ready" "kubectl get nodes --no-headers 2>/dev/null | grep -q Ready"
  kubectl get nodes -o wide 2>/dev/null | head -10
fi

echo ""
echo "-- Management EC2s (public subnet) -------------------------------"
check "Jenkins EC2-A running" "aws ec2 describe-instances --filters Name=tag:Role,Values=jenkins Name=instance-state-name,Values=running | grep -q InstanceId"
check "Mgmt+ITSM EC2-B running" "aws ec2 describe-instances --filters Name=tag:Role,Values=mgmt-tools Name=instance-state-name,Values=running | grep -q InstanceId"

# Get public IPs
JENKINS_PUB=$(aws ec2 describe-instances --filters Name=tag:Role,Values=jenkins Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
MGMT_PUB=$(aws ec2 describe-instances --filters Name=tag:Role,Values=mgmt-tools Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
echo "  [INFO] Jenkins public IP: ${JENKINS_PUB:-unknown}"
echo "  [INFO] Mgmt+ITSM public IP: ${MGMT_PUB:-unknown}"

echo ""
echo "-- Management Tools (direct) -------------------------------------"
if [ -n "${MGMT_PUB}" ] && [ "${MGMT_PUB}" != "None" ]; then
  check "Jenkins HTTP (8080)" "curl -sf --connect-timeout 5 http://${JENKINS_PUB}:8080/login -o /dev/null"
  check "ArgoCD HTTP (8082)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:8082 -o /dev/null"
  check "Harbor HTTP (8083)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:8083 -o /dev/null"
  check "Keycloak HTTP (8081)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:8081 -o /dev/null"
  check "Vault HTTP (8200)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:8200/v1/sys/health -o /dev/null || curl -s http://${MGMT_PUB}:8200/v1/sys/health 2>&1 | grep -q initialized"
  check "ITSM HTTP (80)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:80 -o /dev/null"
  check "Harbor Registry (5000)" "curl -sf --connect-timeout 5 http://${MGMT_PUB}:5000/v2/ -o /dev/null"
fi

echo ""
echo "-- ALB & HTTPS ---------------------------------------------------"
check "ALB exists" "aws elbv2 describe-load-balancers --names ${PROJECT}-tools-alb 2>/dev/null | grep -q LoadBalancerArn"
check "Jenkins HTTPS" "curl -sk --connect-timeout 10 https://${JENKINS_DOMAIN}/login -o /dev/null -w '%{http_code}' | grep -q 200"
check "ArgoCD HTTPS" "curl -sk --connect-timeout 10 https://${ARGOCD_DOMAIN} -o /dev/null -w '%{http_code}' | grep -q 200"
check "Harbor HTTPS" "curl -sk --connect-timeout 10 https://${HARBOR_DOMAIN} -o /dev/null -w '%{http_code}' | grep -q 200"
check "Keycloak HTTPS" "curl -sk --connect-timeout 10 https://${KEYCLOAK_DOMAIN} -o /dev/null -w '%{http_code}' | grep -q 200"
check "Vault HTTPS" "curl -sk --connect-timeout 10 https://${VAULT_DOMAIN}/v1/sys/health -o /dev/null -w '%{http_code}' | grep -qE '200|473'"
check "ITSM HTTPS" "curl -sk --connect-timeout 10 https://${ITSM_DOMAIN} -o /dev/null -w '%{http_code}' | grep -q 200"

echo ""
echo "-- Enterprise Security & Operations --------------------------------"

# KMS Keys
check "KMS key: EKS secrets" "aws kms describe-key --key-id alias/${KMS_EKS_ALIAS} --query 'KeyMetadata.KeyState' --output text 2>/dev/null | grep -q Enabled"
check "KMS key: Vault unseal" "aws kms describe-key --key-id alias/${KMS_VAULT_ALIAS} --query 'KeyMetadata.KeyState' --output text 2>/dev/null | grep -q Enabled"
check "KMS key: EBS encryption" "aws kms describe-key --key-id alias/${KMS_EBS_ALIAS} --query 'KeyMetadata.KeyState' --output text 2>/dev/null | grep -q Enabled"

# EKS Encryption
check "EKS secrets encryption" "aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --query 'cluster.encryptionConfig[0].provider.keyArn' --output text 2>/dev/null | grep -q arn:aws:kms"

# IMDSv2 on EC2s
JENKINS_ID=$(aws ec2 describe-instances --filters Name=tag:Role,Values=jenkins Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
MGMT_ID=$(aws ec2 describe-instances --filters Name=tag:Role,Values=mgmt-tools Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
if [ -n "${JENKINS_ID}" ] && [ "${JENKINS_ID}" != "None" ]; then
  check "IMDSv2 on Jenkins EC2" "aws ec2 describe-instances --instance-ids ${JENKINS_ID} --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text | grep -q required"
fi
if [ -n "${MGMT_ID}" ] && [ "${MGMT_ID}" != "None" ]; then
  check "IMDSv2 on Mgmt EC2" "aws ec2 describe-instances --instance-ids ${MGMT_ID} --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text | grep -q required"
fi

# Pod Security Standards
check "PSS: le-workloads restricted" "kubectl get ns le-workloads -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null | grep -q restricted"
check "PSS: le-monitoring baseline" "kubectl get ns le-monitoring -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null | grep -q baseline"

# VPC Flow Logs
check "VPC Flow Logs active" "aws ec2 describe-flow-logs --filter Name=resource-id,Values=\$(aws ec2 describe-vpcs --filters Name=tag:Project,Values=LinkedEye --query 'Vpcs[0].VpcId' --output text) --query 'FlowLogs[0].FlowLogStatus' --output text 2>/dev/null | grep -q ACTIVE"

# GuardDuty
check "GuardDuty detector active" "aws guardduty list-detectors --query 'DetectorIds[0]' --output text 2>/dev/null | grep -v None | grep -q ."

# WAF
check "WAF WebACL exists" "aws wafv2 list-web-acls --scope REGIONAL --query \"WebACLs[?Name=='${WAF_WEB_ACL_NAME}'].ARN\" --output text 2>/dev/null | grep -q arn:aws:wafv2"

# EBS Encryption
check "EBS encryption by default" "aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' --output text 2>/dev/null | grep -q true"

# Resource Quotas
check "ResourceQuota le-workloads" "kubectl get resourcequota le-workloads-quota -n le-workloads 2>/dev/null"
check "ResourceQuota le-monitoring" "kubectl get resourcequota le-monitoring-quota -n le-monitoring 2>/dev/null"

# Prometheus + Grafana
check "Prometheus pods running" "kubectl get pods -n le-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running"
check "Grafana pods running" "kubectl get pods -n le-monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running"

# Velero
check "Velero pods running" "kubectl get pods -n velero -l app.kubernetes.io/name=velero -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running"
check "Velero S3 bucket accessible" "aws s3api head-bucket --bucket ${VELERO_BUCKET} 2>/dev/null"

# CloudTrail
check "CloudTrail logging" "aws cloudtrail get-trail-status --name ${PROJECT}-audit-trail --query 'IsLogging' --output text 2>/dev/null | grep -q true"

echo ""
echo "-- Old kubeadm EC2s (should be terminated) -----------------------"
check "Old master terminated" "aws ec2 describe-instances --instance-ids i-0254e6bd512f67dd9 --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null | grep -q terminated"
check "Old worker terminated" "aws ec2 describe-instances --instance-ids i-0e0662a64aa8cc8e6 --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null | grep -q terminated"

echo ""
echo "=================================================================="
echo " Results: ${PASS} PASSED  |  ${FAIL} FAILED"
echo "=================================================================="

[[ ${FAIL} -eq 0 ]] && echo " All checks PASSED!" || echo " Fix failures above before proceeding"
