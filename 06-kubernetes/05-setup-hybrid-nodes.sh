#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 5: Setup EKS Hybrid Nodes
# Creates IAM role + SSM Hybrid Activation for on-prem workers.
# Each client site gets 2 physical/VM servers registered as
# EKS worker nodes via nodeadm (no VPN — public API endpoint).
#
# Usage:
#   ./05-setup-hybrid-nodes.sh                    # Create activation
#   ./05-setup-hybrid-nodes.sh register <client>  # Print commands for a client
#   ./05-setup-hybrid-nodes.sh list               # List all 16 clients
#   ./05-setup-hybrid-nodes.sh register-all       # Print commands for all clients
#   ./05-setup-hybrid-nodes.sh firewall <client>  # Print FortiGate rules
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

ACTION="${1:-create}"
CLIENT_NAME="${2:-}"

# ─── 16 CLIENT DEFINITIONS ───────────────────────────────────
# Format: label:subnet:fqdn:firewall:namespace
CLIENTS=(
  "indmoney:10.172.0.10:fs-le-indmoney.finspot.in:FortiGate 60F:le-indmoney-prod"
  "neo-wealth:10.40.1.10:fs-le-neo.finspot.in:FortiGate 60F:le-neo-wealth-prod"
  "dx:10.10.10.110:fs-le-dx.finspot.in:FortiGate 100F:le-dx-prod"
  "ifsc:10.40.40.23:fs-le-ifsc.finspot.in:FortiGate 60F:le-ifsc-prod"
  "w2w:10.50.x.x:fs-le-w2w.finspot.in:FortiGate 60F:le-w2w-prod"
  "ftc:10.60.x.x:fs-le-ftc.finspot.in:FortiGate 60F:le-ftc-prod"
  "pl-india:10.70.x.x:fs-le-pl.finspot.in:FortiGate 60F:le-pl-india-prod"
  "isv1:10.80.x.x:fs-le-isv1.finspot.in:FortiGate 60F:le-isv1-prod"
  "isv2:10.81.x.x:fs-le-isv2.finspot.in:FortiGate 60F:le-isv2-prod"
  "isv3:10.82.x.x:fs-le-isv3.finspot.in:FortiGate 60F:le-isv3-prod"
  "isv4:10.83.x.x:fs-le-isv4.finspot.in:FortiGate 60F:le-isv4-prod"
  "isv5:10.84.x.x:fs-le-isv5.finspot.in:FortiGate 60F:le-isv5-prod"
  "mirae:10.90.x.x:fs-le-mirae.finspot.in:FortiGate 100F:le-mirae-prod"
  "smifs:10.92.x.x:fs-le-smifs.finspot.in:FortiGate 60F:le-smifs-prod"
  "lemonn:10.94.x.x:fs-le-lemonn.finspot.in:FortiGate 60F:le-lemonn-prod"
)

# Helper: find client entry by label
find_client() {
  local SEARCH="$1"
  for ENTRY in "${CLIENTS[@]}"; do
    local LABEL=$(echo "${ENTRY}" | cut -d: -f1)
    if [ "${LABEL}" = "${SEARCH}" ]; then
      echo "${ENTRY}"
      return 0
    fi
  done
  return 1
}

echo "============================================================"
echo " EKS Hybrid Nodes Setup: ${EKS_CLUSTER_NAME}"
echo " Mode: No VPN — workers connect via public EKS API (HTTPS)"
echo "============================================================"

# ─── LIST ALL CLIENTS ─────────────────────────────────────────
if [ "${ACTION}" = "list" ]; then
  echo ""
  printf "  %-4s %-14s %-16s %-35s %-15s %s\n" "#" "CLIENT" "SUBNET" "FQDN" "FIREWALL" "NAMESPACE"
  printf "  %-4s %-14s %-16s %-35s %-15s %s\n" "---" "-----------" "--------------" "-------------------------------" "-------------" "-------------------"
  NUM=1
  for ENTRY in "${CLIENTS[@]}"; do
    LABEL=$(echo "${ENTRY}" | cut -d: -f1)
    SUBNET=$(echo "${ENTRY}" | cut -d: -f2)
    FQDN=$(echo "${ENTRY}" | cut -d: -f3)
    FW=$(echo "${ENTRY}" | cut -d: -f4)
    NS=$(echo "${ENTRY}" | cut -d: -f5)
    printf "  %-4s %-14s %-16s %-35s %-15s %s\n" "${NUM}" "${LABEL}" "${SUBNET}" "${FQDN}" "${FW}" "${NS}"
    ((NUM++))
  done
  echo ""
  echo "  Total: ${#CLIENTS[@]} clients, $((${#CLIENTS[@]} * 2)) worker nodes"
  exit 0
fi

# ─── FIREWALL RULES ──────────────────────────────────────────
if [ "${ACTION}" = "firewall" ]; then
  if [ -n "${CLIENT_NAME}" ]; then
    CLIENT_ENTRY=$(find_client "${CLIENT_NAME}" || true)
    if [ -z "${CLIENT_ENTRY}" ]; then
      echo "ERROR: Client '${CLIENT_NAME}' not found. Run: $0 list"
      exit 1
    fi
    FW=$(echo "${CLIENT_ENTRY}" | cut -d: -f4)
    echo ""
    echo "=== FortiGate Firewall Rules for: ${CLIENT_NAME} (${FW}) ==="
  else
    echo ""
    echo "=== FortiGate Firewall Rules (ALL CLIENTS) ==="
  fi
  echo ""
  echo "  ALLOW OUTBOUND (from worker servers):"
  echo "  ──────────────────────────────────────"
  echo "  Port 443 (TCP) → EKS API: ${EKS_ENDPOINT}"
  echo "  Port 443 (TCP) → *.amazonaws.com (SSM, ECR, S3)"
  echo ""
  echo "  NO VPN REQUIRED. NO INBOUND RULES NEEDED."
  echo "  Just outbound HTTPS 443 to internet."
  echo ""
  echo "  FortiGate CLI example:"
  echo "  ─────────────────────"
  echo "  config firewall policy"
  echo "    edit 0"
  echo "      set name \"EKS-Hybrid-Outbound\""
  echo "      set srcintf \"internal\""
  echo "      set dstintf \"wan1\""
  echo "      set srcaddr \"worker-servers\""
  echo "      set dstaddr \"all\""
  echo "      set action accept"
  echo "      set schedule \"always\""
  echo "      set service \"HTTPS\""
  echo "      set nat enable"
  echo "    next"
  echo "  end"
  exit 0
fi

# ─── REGISTER ALL CLIENTS ────────────────────────────────────
if [ "${ACTION}" = "register-all" ]; then
  echo ""
  echo "=== Registration Commands for ALL ${#CLIENTS[@]} Clients ==="
  for ENTRY in "${CLIENTS[@]}"; do
    LABEL=$(echo "${ENTRY}" | cut -d: -f1)
    echo ""
    echo "================================================================"
    echo " CLIENT: ${LABEL}"
    echo "================================================================"
    # Re-invoke self for each client
    "$0" register "${LABEL}"
  done
  exit 0
fi

if [ "${ACTION}" = "register" ]; then
  # ─── PRINT REGISTRATION COMMANDS FOR A CLIENT ─────────────
  if [ -z "${CLIENT_NAME}" ]; then
    echo ""
    echo "Usage: $0 register <client-name>"
    echo ""
    echo "Available clients:"
    for ENTRY in "${CLIENTS[@]}"; do
      echo "  $(echo "${ENTRY}" | cut -d: -f1)"
    done
    exit 1
  fi

  # Validate client exists
  CLIENT_ENTRY=$(find_client "${CLIENT_NAME}" || true)
  if [ -z "${CLIENT_ENTRY}" ]; then
    echo "ERROR: Client '${CLIENT_NAME}' not found."
    echo "Available clients:"
    for ENTRY in "${CLIENTS[@]}"; do
      echo "  $(echo "${ENTRY}" | cut -d: -f1)"
    done
    exit 1
  fi

  CLIENT_SUBNET=$(echo "${CLIENT_ENTRY}" | cut -d: -f2)
  CLIENT_FQDN=$(echo "${CLIENT_ENTRY}" | cut -d: -f3)
  CLIENT_FW=$(echo "${CLIENT_ENTRY}" | cut -d: -f4)
  CLIENT_NS=$(echo "${CLIENT_ENTRY}" | cut -d: -f5)
  NODE_COUNT="${3:-2}"  # Default 2 nodes for HA

  echo ""
  echo "=== On-Prem Node Registration for: ${CLIENT_NAME} ==="
  echo "    Subnet:    ${CLIENT_SUBNET}"
  echo "    FQDN:      ${CLIENT_FQDN}"
  echo "    Firewall:  ${CLIENT_FW}"
  echo "    Namespace: ${CLIENT_NS}"
  echo "    Nodes:     ${NODE_COUNT} (HA)"
  echo "    Connection: Public EKS API (no VPN)"
  echo ""
  echo "################################################################"
  echo "# PREREQUISITE: FortiGate outbound HTTPS 443 must be allowed"
  echo "# (see: $0 firewall ${CLIENT_NAME})"
  echo "################################################################"

  for i in $(seq 1 ${NODE_COUNT}); do
    echo ""
    echo "################################################################"
    echo "# WORKER NODE ${i} of ${NODE_COUNT}: ${CLIENT_NAME}-worker-${i}"
    echo "################################################################"
    echo ""
    echo "# Run these on the on-prem server #${i} at ${CLIENT_NAME}'s site:"
    echo ""
    echo "# 1. Install SSM Agent"
    echo "sudo snap install amazon-ssm-agent --classic"
    echo "sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent"
    echo ""
    echo "# 2. Register with SSM Hybrid Activation"
    echo "sudo amazon-ssm-agent -register \\"
    echo "  -code \"\${ACTIVATION_CODE}\" \\"
    echo "  -id \"\${ACTIVATION_ID}\" \\"
    echo "  -region ${AWS_REGION}"
    echo "sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent"
    echo ""
    echo "# 3. Install nodeadm (EKS node bootstrap tool)"
    echo "curl -fsSL https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm -o /usr/local/bin/nodeadm"
    echo "chmod +x /usr/local/bin/nodeadm"
    echo ""
    echo "# 4. Create nodeadm config"
    echo "sudo mkdir -p /etc/eks"
    echo "cat > /etc/eks/nodeadm-config.yaml <<'EOF'"
    echo "apiVersion: node.eks.aws/v1alpha1"
    echo "kind: NodeConfig"
    echo "spec:"
    echo "  cluster:"
    echo "    name: ${EKS_CLUSTER_NAME}"
    echo "    region: ${AWS_REGION}"
    echo "  hybrid:"
    echo "    ssm:"
    echo "      activationCode: \"\${ACTIVATION_CODE}\""
    echo "      activationId: \"\${ACTIVATION_ID}\""
    echo "    nodeName: \"${CLIENT_NAME}-worker-${i}\""
    echo "EOF"
    echo ""
    echo "# 5. Bootstrap the node (connects to EKS via HTTPS 443 — no VPN)"
    echo "sudo nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml"
    echo ""
  done

  echo "################################################################"
  echo "# VERIFY & LABEL (run from AWS / EC2-B with kubectl access)"
  echo "################################################################"
  echo ""
  echo "# Verify all ${NODE_COUNT} nodes joined"
  echo "kubectl get nodes | grep ${CLIENT_NAME}"
  echo ""
  echo "# Label nodes for client isolation + namespace binding"
  for i in $(seq 1 ${NODE_COUNT}); do
    echo "kubectl label node ${CLIENT_NAME}-worker-${i} client=${CLIENT_NAME} namespace=${CLIENT_NS} --overwrite"
  done
  echo ""
  echo "# Taint nodes for dedicated workloads (optional but recommended)"
  for i in $(seq 1 ${NODE_COUNT}); do
    echo "kubectl taint node ${CLIENT_NAME}-worker-${i} client=${CLIENT_NAME}:NoSchedule --overwrite 2>/dev/null || true"
  done
  echo ""
  echo "# Deploy workloads to client namespace"
  echo "kubectl get pods -n ${CLIENT_NS}"
  echo ""
  echo "# Expected output:"
  echo "# NAME                    STATUS   ROLES    VERSION"
  for i in $(seq 1 ${NODE_COUNT}); do
    echo "# ${CLIENT_NAME}-worker-${i}   Ready    <none>   v1.31"
  done
  echo ""
  exit 0
fi

# ─── CREATE HYBRID NODE IAM ROLE ────────────────────────────
echo "[HYBRID-1] Creating Hybrid Node IAM role"

HYBRID_TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ssm.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

aws iam create-role \
  --role-name "${HYBRID_NODE_ROLE_NAME}" \
  --assume-role-policy-document "${HYBRID_TRUST}" \
  --description "LinkedEye EKS Hybrid Node - on-prem workers" \
  --tags Key=Project,Value=${TAG_PROJECT} Key=Environment,Value=${TAG_ENV} \
  2>/dev/null || echo "    (role may already exist)"

# Required policies for EKS Hybrid Nodes
for POLICY_ARN in \
  "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" \
  "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" \
  "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" \
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"; do
  aws iam attach-role-policy \
    --role-name "${HYBRID_NODE_ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}" 2>/dev/null || true
done

echo "    Role: ${HYBRID_NODE_ROLE_NAME}"

# ─── CREATE SSM HYBRID ACTIVATION ───────────────────────────
echo "[HYBRID-2] Creating SSM Hybrid Activation"
echo "    Allows up to 50 on-prem servers to register (valid 30 days)"

ACTIVATION=$(aws ssm create-activation \
  --iam-role "${HYBRID_NODE_ROLE_NAME}" \
  --registration-limit 50 \
  --default-instance-name "${PROJECT}-hybrid-worker" \
  --description "LinkedEye EKS Hybrid Node activation for on-prem client workers" \
  --tags "Key=Project,Value=${TAG_PROJECT}" "Key=Environment,Value=${TAG_ENV}" \
  --output json)

ACTIVATION_ID=$(echo "${ACTIVATION}" | jq -r '.ActivationId')
ACTIVATION_CODE=$(echo "${ACTIVATION}" | jq -r '.ActivationCode')

echo "    Activation ID:   ${ACTIVATION_ID}"
echo "    Activation Code: ${ACTIVATION_CODE}"

# ─── UPDATE aws-auth ConfigMap ──────────────────────────────
echo "[HYBRID-3] Updating aws-auth ConfigMap for hybrid node role"
HYBRID_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${HYBRID_NODE_ROLE_NAME}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${HYBRID_ROLE_ARN}
      username: system:node:{{SessionName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-mgmt-ec2-role
      username: mgmt-ec2-user
      groups:
        - system:masters
EOF
echo "    aws-auth updated with hybrid node role"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export HYBRID_ROLE_ARN="${HYBRID_ROLE_ARN}"
export HYBRID_ACTIVATION_ID="${ACTIVATION_ID}"
export HYBRID_ACTIVATION_CODE="${ACTIVATION_CODE}"
EOF

echo ""
echo "================================================================"
echo "[DONE] EKS Hybrid Node infrastructure ready"
echo ""
echo "  Activation ID:   ${ACTIVATION_ID}"
echo "  Activation Code: ${ACTIVATION_CODE}"
echo ""
echo "  IMPORTANT: Save the activation code — it cannot be retrieved later!"
echo ""
echo "  To register a client's on-prem worker:"
echo "    $0 register <client-name>"
echo ""
echo "  Example:"
echo "    $0 register acme-corp"
echo ""
echo "  This will print the exact commands to run on the on-prem server."
echo ""
echo "  Each client's node will be labeled: client=<client-name>"
echo "  Use nodeSelector/affinity to isolate workloads per client."
echo "================================================================"
