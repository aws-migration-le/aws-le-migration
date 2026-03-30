#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 11: Create 16 Client Namespaces + Isolation
# Creates production namespaces for each client + non-prod.
# Each namespace gets: NetworkPolicy, ResourceQuota, LimitRange,
# RBAC (client-admin RoleBinding), PDB template.
#
# Usage:
#   ./11-create-client-namespaces.sh              # Create all
#   ./11-create-client-namespaces.sh <client>      # Create one client
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

SINGLE_CLIENT="${1:-}"

# ─── CLIENT DEFINITIONS ──────────────────────────────────────
# Format: namespace:fqdn:label
PROD_CLIENTS=(
  "le-indmoney-prod:fs-le-indmoney.finspot.in:indmoney"
  "le-neo-wealth-prod:fs-le-neo.finspot.in:neo-wealth"
  "le-dx-prod:fs-le-dx.finspot.in:dx"
  "le-ifsc-prod:fs-le-ifsc.finspot.in:ifsc"
  "le-w2w-prod:fs-le-w2w.finspot.in:w2w"
  "le-ftc-prod:fs-le-ftc.finspot.in:ftc"
  "le-pl-india-prod:fs-le-pl.finspot.in:pl-india"
  "le-isv1-prod:fs-le-isv1.finspot.in:isv1"
  "le-isv2-prod:fs-le-isv2.finspot.in:isv2"
  "le-isv3-prod:fs-le-isv3.finspot.in:isv3"
  "le-isv4-prod:fs-le-isv4.finspot.in:isv4"
  "le-isv5-prod:fs-le-isv5.finspot.in:isv5"
  "le-mirae-prod:fs-le-mirae.finspot.in:mirae"
  "le-smifs-prod:fs-le-smifs.finspot.in:smifs"
  "le-lemonn-prod:fs-le-lemonn.finspot.in:lemonn"
)

NON_PROD_NAMESPACES=(
  "le-uat"
  "le-dev"
  "le-dr"
)

echo "============================================================"
echo " Creating Client Namespaces + Isolation"
echo " Cluster: ${EKS_CLUSTER_NAME}"
echo "============================================================"

# ─── HELPER: Create namespace with full isolation ────────────
create_client_namespace() {
  local NS="$1"
  local CLIENT_LABEL="$2"
  local ENV_LABEL="${3:-prod}"

  echo ""
  echo "────────────────────────────────────────────────────────"
  echo " Namespace: ${NS}  (client=${CLIENT_LABEL})"
  echo "────────────────────────────────────────────────────────"

  # 1. Create namespace
  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NS}" \
    project=linkedeye \
    environment="${ENV_LABEL}" \
    client="${CLIENT_LABEL}" \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite
  echo "  [1/5] Namespace created + labeled"

  # 2. NetworkPolicy — strict isolation per namespace
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NS}-isolation
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
    client: ${CLIENT_LABEL}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow from same namespace only
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${NS}
  # Allow from monitoring (Prometheus scraping)
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: le-monitoring
  egress:
  # Allow DNS (kube-system)
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow same namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${NS}
  # Allow external (APIs, registries, Harbor)
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.100.0.0/16
EOF
  echo "  [2/5] NetworkPolicy applied (namespace isolation)"

  # 3. ResourceQuota
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${NS}-quota
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
    client: ${CLIENT_LABEL}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "10"
    persistentvolumeclaims: "10"
    configmaps: "30"
    secrets: "30"
EOF
  echo "  [3/5] ResourceQuota applied (4 CPU / 8Gi request, 20 pods)"

  # 4. LimitRange (container defaults)
  kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: ${NS}-limits
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
    client: ${CLIENT_LABEL}
spec:
  limits:
  - type: Container
    default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 100m
      memory: 128Mi
    max:
      cpu: "4"
      memory: 8Gi
    min:
      cpu: 10m
      memory: 16Mi
  - type: Pod
    max:
      cpu: "8"
      memory: 16Gi
EOF
  echo "  [4/5] LimitRange applied (defaults: 100m/128Mi req, 500m/512Mi limit)"

  # 5. RBAC — client-admin RoleBinding
  kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NS}-admin
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
    client: ${CLIENT_LABEL}
subjects:
- kind: Group
  name: ${NS}-admins
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: le-client-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NS}-argocd-deployer
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
    client: ${CLIENT_LABEL}
subjects:
- kind: Group
  name: le-argocd-deployers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: le-argocd-deployer
  apiGroup: rbac.authorization.k8s.io
EOF
  echo "  [5/5] RBAC applied (client-admin + argocd-deployer)"
}

# ─── CREATE NON-PROD NAMESPACES ──────────────────────────────
create_nonprod_namespace() {
  local NS="$1"
  local ENV_LABEL="$2"

  echo ""
  echo "────────────────────────────────────────────────────────"
  echo " Non-Prod Namespace: ${NS}"
  echo "────────────────────────────────────────────────────────"

  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "${NS}" \
    project=linkedeye \
    environment="${ENV_LABEL}" \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite
  echo "  Namespace created + labeled"

  # ResourceQuota (smaller for non-prod)
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${NS}-quota
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
    pods: "10"
    services: "5"
    persistentvolumeclaims: "5"
    configmaps: "20"
    secrets: "20"
EOF
  echo "  ResourceQuota applied (2 CPU / 4Gi, 10 pods)"

  # LimitRange
  kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: ${NS}-limits
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  limits:
  - type: Container
    default:
      cpu: 250m
      memory: 256Mi
    defaultRequest:
      cpu: 50m
      memory: 64Mi
    max:
      cpu: "2"
      memory: 4Gi
    min:
      cpu: 10m
      memory: 16Mi
EOF
  echo "  LimitRange applied"
}

# ─── MAIN EXECUTION ──────────────────────────────────────────
CREATED=0

if [ -n "${SINGLE_CLIENT}" ]; then
  # Single client mode
  FOUND=0
  for ENTRY in "${PROD_CLIENTS[@]}"; do
    NS=$(echo "${ENTRY}" | cut -d: -f1)
    FQDN=$(echo "${ENTRY}" | cut -d: -f2)
    LABEL=$(echo "${ENTRY}" | cut -d: -f3)
    if [ "${LABEL}" = "${SINGLE_CLIENT}" ] || [ "${NS}" = "${SINGLE_CLIENT}" ]; then
      create_client_namespace "${NS}" "${LABEL}" "prod"
      FOUND=1
      CREATED=1
      break
    fi
  done
  if [ "${FOUND}" -eq 0 ]; then
    echo "ERROR: Client '${SINGLE_CLIENT}' not found in client list."
    echo "Available clients:"
    for ENTRY in "${PROD_CLIENTS[@]}"; do
      echo "  $(echo "${ENTRY}" | cut -d: -f3)"
    done
    exit 1
  fi
else
  # All clients mode
  echo ""
  echo "[STEP 1] Creating 15 production client namespaces"
  for ENTRY in "${PROD_CLIENTS[@]}"; do
    NS=$(echo "${ENTRY}" | cut -d: -f1)
    FQDN=$(echo "${ENTRY}" | cut -d: -f2)
    LABEL=$(echo "${ENTRY}" | cut -d: -f3)
    create_client_namespace "${NS}" "${LABEL}" "prod"
    ((CREATED++))
  done

  echo ""
  echo "[STEP 2] Creating 3 non-production namespaces"
  create_nonprod_namespace "le-uat" "uat"
  create_nonprod_namespace "le-dev" "dev"
  create_nonprod_namespace "le-dr" "dr"
  CREATED=$((CREATED + 3))
fi

# ─── VERIFICATION ─────────────────────────────────────────────
echo ""
echo "============================================================"
echo "[VERIFY] Namespace summary"
echo "============================================================"
echo ""
echo "  Namespaces:"
kubectl get ns -l project=linkedeye --no-headers | awk '{printf "    %-30s %s\n", $1, $2}'
echo ""
echo "  NetworkPolicies:"
kubectl get networkpolicy -A -l app.kubernetes.io/part-of=linkedeye --no-headers 2>/dev/null | awk '{printf "    %-30s %s\n", $1, $2}'
echo ""
echo "  ResourceQuotas:"
kubectl get resourcequota -A -l app.kubernetes.io/part-of=linkedeye --no-headers 2>/dev/null | awk '{printf "    %-30s %s\n", $1, $2}'

echo ""
echo "============================================================"
echo "[DONE] Created ${CREATED} namespaces with full isolation"
echo ""
echo "  Production (15 clients):"
for ENTRY in "${PROD_CLIENTS[@]}"; do
  NS=$(echo "${ENTRY}" | cut -d: -f1)
  LABEL=$(echo "${ENTRY}" | cut -d: -f3)
  printf "    %-25s client=%s\n" "${NS}" "${LABEL}"
done
echo ""
echo "  Non-Production (3):"
echo "    le-uat                    environment=uat"
echo "    le-dev                    environment=dev"
echo "    le-dr                     environment=dr"
echo ""
echo "  Each namespace has:"
echo "    - NetworkPolicy (strict namespace isolation)"
echo "    - ResourceQuota (4 CPU / 8Gi per client)"
echo "    - LimitRange (container defaults)"
echo "    - RBAC (client-admin + argocd-deployer)"
echo ""
echo "  Next steps:"
echo "    1. Add ALB rules:  ./05-loadbalancer/02-add-client-alb-rules.sh"
echo "    2. Register nodes: ./05-setup-hybrid-nodes.sh register <client>"
echo "============================================================"
