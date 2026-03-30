#!/usr/bin/env bash
# ============================================================
# PHASE 5 — STEP 1: Create ALB for Management Tools + ITSM
# Routes *.finspot.in to EC2-A (Jenkins) and EC2-B (Mgmt+ITSM)
# Both EC2s are in PUBLIC subnet with public IPs.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Creating ALB for Management Tools (*.finspot.in)"
echo "============================================================"

# ─── CHECK/REQUEST ACM CERTIFICATE ──────────────────────────
echo "[ALB-1] Looking for ACM certificate for *.finspot.in"
ACM_ARN=$(aws acm list-certificates \
  --query "CertificateSummaryList[?DomainName=='*.finspot.in'].CertificateArn" \
  --output text 2>/dev/null)

if [ -z "${ACM_ARN}" ] || [ "${ACM_ARN}" = "None" ]; then
  echo "    No ACM certificate found for *.finspot.in"
  echo "    Requesting new certificate..."
  ACM_ARN=$(aws acm request-certificate \
    --domain-name "*.finspot.in" \
    --subject-alternative-names "finspot.in" \
    --validation-method DNS \
    --tags Key=Project,Value=${TAG_PROJECT} \
    --query 'CertificateArn' --output text)
  echo "    Certificate requested: ${ACM_ARN}"
  echo "    ACTION REQUIRED: Add DNS validation records"
  sleep 30
  aws acm describe-certificate --certificate-arn "${ACM_ARN}" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output table
fi
echo "    ACM certificate: ${ACM_ARN}"

# ─── CREATE ALB ─────────────────────────────────────────────
echo "[ALB-2] Creating Application Load Balancer"
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT}-tools-alb" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "${PUB_SUBNET_AZ1}" "${PUB_SUBNET_AZ2}" \
  --security-groups "${SG_ALB}" \
  --tags "Key=Name,Value=${PROJECT}-tools-alb" "Key=Project,Value=${TAG_PROJECT}" "Key=Environment,Value=${TAG_ENV}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "    ALB: ${ALB_ARN}"
echo "    DNS: ${ALB_DNS}"

# ─── TARGET GROUPS ──────────────────────────────────────────
echo "[ALB-3] Creating target groups"

# Jenkins (EC2-A)
TG_JENKINS=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-jenkins" \
  --protocol HTTP --port 8080 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/login" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_JENKINS}" \
  --targets "Id=${JENKINS_EC2_ID},Port=8080"
echo "    TG Jenkins: → EC2-A:8080"

# ArgoCD (EC2-B)
TG_ARGOCD=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-argocd" \
  --protocol HTTP --port 8082 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_ARGOCD}" \
  --targets "Id=${MGMT_EC2_ID},Port=8082"
echo "    TG ArgoCD: → EC2-B:8082"

# Harbor (EC2-B)
TG_HARBOR=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-harbor" \
  --protocol HTTP --port 8083 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_HARBOR}" \
  --targets "Id=${MGMT_EC2_ID},Port=8083"
echo "    TG Harbor: → EC2-B:8083"

# Keycloak (EC2-B)
TG_KEYCLOAK=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-keycloak" \
  --protocol HTTP --port 8081 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_KEYCLOAK}" \
  --targets "Id=${MGMT_EC2_ID},Port=8081"
echo "    TG Keycloak: → EC2-B:8081"

# Vault (EC2-B)
TG_VAULT=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-vault" \
  --protocol HTTP --port 8200 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/v1/sys/health" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --matcher HttpCode=200,429,472,473,501,503 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_VAULT}" \
  --targets "Id=${MGMT_EC2_ID},Port=8200"
echo "    TG Vault: → EC2-B:8200"

# ITSM (EC2-B)
TG_ITSM=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-itsm" \
  --protocol HTTP --port 80 \
  --vpc-id "${VPC_ID}" \
  --target-type instance \
  --health-check-path "/" \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn "${TG_ITSM}" \
  --targets "Id=${MGMT_EC2_ID},Port=80"
echo "    TG ITSM: → EC2-B:80"

# ─── HTTPS LISTENER (443) ──────────────────────────────────
echo "[ALB-4] Creating HTTPS listener with host-based routing"
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "${ALB_ARN}" \
  --protocol HTTPS --port 443 \
  --certificates "CertificateArn=${ACM_ARN}" \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions "Type=fixed-response,FixedResponseConfig={StatusCode=404,ContentType=text/plain,MessageBody=Not Found}" \
  --query 'Listeners[0].ListenerArn' --output text)

PRIORITY=1
for RULE_DEF in \
  "${JENKINS_DOMAIN}:${TG_JENKINS}" \
  "${ARGOCD_DOMAIN}:${TG_ARGOCD}" \
  "${HARBOR_DOMAIN}:${TG_HARBOR}" \
  "${KEYCLOAK_DOMAIN}:${TG_KEYCLOAK}" \
  "${VAULT_DOMAIN}:${TG_VAULT}" \
  "${ITSM_DOMAIN}:${TG_ITSM}"; do

  HOST=$(echo "${RULE_DEF}" | cut -d: -f1)
  TG=$(echo "${RULE_DEF}" | cut -d: -f2-)

  aws elbv2 create-rule \
    --listener-arn "${LISTENER_ARN}" \
    --priority "${PRIORITY}" \
    --conditions "Field=host-header,Values=[${HOST}]" \
    --actions "Type=forward,TargetGroupArn=${TG}"
  echo "    Rule ${PRIORITY}: ${HOST}"
  ((PRIORITY++))
done

# ─── HTTP → HTTPS REDIRECT ──────────────────────────────────
echo "[ALB-5] Creating HTTP→HTTPS redirect"
aws elbv2 create-listener \
  --load-balancer-arn "${ALB_ARN}" \
  --protocol HTTP --port 80 \
  --default-actions "Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export ALB_ARN="${ALB_ARN}"
export ALB_DNS="${ALB_DNS}"
export ACM_ARN="${ACM_ARN}"
EOF

echo ""
echo "[DONE] ALB created with host-based routing"
echo "  ALB DNS: ${ALB_DNS}"
echo ""
echo "  Routes (all via EC2-A and EC2-B):"
echo "    ${JENKINS_DOMAIN}  → EC2-A:8080"
echo "    ${ARGOCD_DOMAIN}   → EC2-B:8082"
echo "    ${HARBOR_DOMAIN}   → EC2-B:8083"
echo "    ${KEYCLOAK_DOMAIN} → EC2-B:8081"
echo "    ${VAULT_DOMAIN}    → EC2-B:8200"
echo "    ${ITSM_DOMAIN}     → EC2-B:80"
echo ""
echo "  Create DNS CNAME: *.finspot.in → ${ALB_DNS}"
