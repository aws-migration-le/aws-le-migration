#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 4: Create EKS Cluster (Hybrid Nodes)
# Control plane on AWS, workers will be on-prem per client.
# Endpoint: public+private (on-prem nodes connect via public).
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Creating EKS Cluster: ${EKS_CLUSTER_NAME}"
echo " Mode: Hybrid Nodes (control plane AWS, workers on-prem)"
echo "============================================================"

# ─── CREATE CLUSTER ─────────────────────────────────────────
echo "[EKS-1] Creating EKS cluster (this takes ~10 minutes)"
echo "    Endpoint: public + private (on-prem nodes need public API)"

aws eks create-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --role-arn "${EKS_CLUSTER_ROLE_ARN}" \
  --kubernetes-version "${EKS_K8S_VERSION}" \
  --resources-vpc-config \
    "subnetIds=${EKS_SUBNET_AZ1B},${EKS_SUBNET_AZ1C},${PUB_SUBNET_AZ1},${PUB_SUBNET_AZ2},\
securityGroupIds=${SG_EKS_CLUSTER},\
endpointPublicAccess=true,endpointPrivateAccess=true" \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}' \
  --tags "Project=${TAG_PROJECT},Environment=${TAG_ENV},Owner=${TAG_OWNER}"

echo ""
echo "[EKS-2] Waiting for EKS cluster to become ACTIVE..."
echo "    (This typically takes 8-12 minutes)"
aws eks wait cluster-active --name "${EKS_CLUSTER_NAME}"
echo "    Cluster is ACTIVE"

# ─── OIDC PROVIDER ──────────────────────────────────────────
echo "[EKS-3] Creating OIDC identity provider for IRSA"
OIDC_URL=$(aws eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo "${OIDC_URL}" | awk -F/ '{print $NF}')

if ! aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '${OIDC_ID}')]" --output text | grep -q arn; then
  THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.${AWS_REGION}.amazonaws.com \
    -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null | \
    openssl x509 -fingerprint -noout 2>/dev/null | \
    sed 's/://g' | awk -F= '{print tolower($2)}')
  [ -z "${THUMBPRINT}" ] && THUMBPRINT="9e99a48a9960b14926bb7f3b02e22da2b0ab7280"

  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "${THUMBPRINT}" \
    --tags Key=Project,Value=${TAG_PROJECT}
  echo "    OIDC provider created: ${OIDC_ID}"
else
  echo "    OIDC provider already exists: ${OIDC_ID}"
fi

# ─── IRSA ROLE: EBS CSI Driver ──────────────────────────────
echo "[EKS-4] Creating IRSA role for EBS CSI driver"
EBS_CSI_TRUST=$(cat <<TRUSTEOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
TRUSTEOF
)

aws iam create-role \
  --role-name "${PROJECT}-ebs-csi-driver-role" \
  --assume-role-policy-document "${EBS_CSI_TRUST}" \
  --description "LinkedEye EBS CSI Driver IRSA role" \
  --tags Key=Project,Value=${TAG_PROJECT} 2>/dev/null || true

aws iam attach-role-policy \
  --role-name "${PROJECT}-ebs-csi-driver-role" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# ─── UPDATE KUBECONFIG ──────────────────────────────────────
echo "[EKS-5] Updating local kubeconfig"
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}"

# ─── PERSIST ────────────────────────────────────────────────
EKS_CLUSTER_ARN=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.arn' --output text)
EKS_ENDPOINT=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.endpoint' --output text)
EKS_CA=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.certificateAuthority.data' --output text)

cat >> /tmp/le-network-ids.env <<EOF
export EKS_CLUSTER_ARN="${EKS_CLUSTER_ARN}"
export EKS_ENDPOINT="${EKS_ENDPOINT}"
export EKS_CA="${EKS_CA}"
export OIDC_ID="${OIDC_ID}"
export OIDC_URL="${OIDC_URL}"
export EBS_CSI_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-ebs-csi-driver-role"
EOF

echo ""
echo "[DONE] EKS Cluster created (Hybrid mode ready)"
echo "  Cluster:    ${EKS_CLUSTER_NAME}"
echo "  ARN:        ${EKS_CLUSTER_ARN}"
echo "  Endpoint:   ${EKS_ENDPOINT}"
echo "  OIDC:       ${OIDC_ID}"
echo "  Version:    ${EKS_K8S_VERSION}"
echo "  API Access: Public + Private"
echo ""
echo "  NO managed node group — workers are on-prem (Hybrid Nodes)"
echo "  NEXT: Run 06-kubernetes/05-setup-hybrid-nodes.sh"
