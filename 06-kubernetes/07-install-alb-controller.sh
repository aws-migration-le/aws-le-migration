#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 7: (OPTIONAL) AWS Load Balancer Controller
# NOTE: For Hybrid Nodes architecture, ALB is managed via CLI
#       (see 05-loadbalancer/01-create-alb-for-tools.sh).
#       Only install this if EKS workloads need their own
#       Ingress-managed ALBs in the future.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " (OPTIONAL) AWS Load Balancer Controller on EKS"
echo " Current ALB is managed via CLI — this is for future use"
echo "============================================================"

echo ""
echo "  The ALB for management tools (*.finspot.in) is created by:"
echo "    05-loadbalancer/01-create-alb-for-tools.sh"
echo ""
echo "  The AWS LB Controller is only needed if EKS workloads on"
echo "  on-prem hybrid nodes need their own ALBs via K8s Ingress."
echo ""

read -p "  Install AWS LB Controller? (y/N): " INSTALL
if [ "${INSTALL}" != "y" ] && [ "${INSTALL}" != "Y" ]; then
  echo "  Skipping. Run this script again if needed later."
  exit 0
fi

# ─── IRSA ROLE ──────────────────────────────────────────────
echo "[ALB-1] Creating IRSA role for AWS Load Balancer Controller"
OIDC_ID=${OIDC_ID:-$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text | awk -F/ '{print $NF}')}

ALB_TRUST=$(cat <<TRUSTEOF
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
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
TRUSTEOF
)

aws iam create-role \
  --role-name "${PROJECT}-alb-controller-role" \
  --assume-role-policy-document "${ALB_TRUST}" \
  --tags Key=Project,Value=${TAG_PROJECT} 2>/dev/null || true

curl -fsSL -o /tmp/alb-controller-policy.json \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"

ALB_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${PROJECT}-alb-controller-policy" \
  --policy-document file:///tmp/alb-controller-policy.json \
  --tags Key=Project,Value=${TAG_PROJECT} \
  --query 'Policy.Arn' --output text 2>/dev/null || \
  echo "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${PROJECT}-alb-controller-policy")

aws iam attach-role-policy \
  --role-name "${PROJECT}-alb-controller-role" \
  --policy-arn "${ALB_POLICY_ARN}"

ALB_CONTROLLER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-alb-controller-role"

# ─── HELM INSTALL ────────────────────────────────────────────
echo "[ALB-2] Installing via Helm"
helm repo add eks https://aws.github.io/eks-charts
helm repo update

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: ${ALB_CONTROLLER_ROLE_ARN}
EOF

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="${EKS_CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --set replicaCount=1

echo ""
echo "[DONE] AWS Load Balancer Controller installed (optional)"
