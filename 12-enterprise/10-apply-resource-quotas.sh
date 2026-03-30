#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 10: Apply Resource Quotas & Limit Ranges
# ResourceQuota per namespace + LimitRange defaults.
#   le-workloads:  16 CPU / 32Gi / 100 pods
#   le-monitoring: 8 CPU / 16Gi / 50 pods
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Applying Resource Quotas & Limit Ranges"
echo "============================================================"

# ─── 1. le-workloads RESOURCE QUOTA ────────────────────────
echo "[1/4] ResourceQuota for le-workloads (16 CPU / 32Gi / 100 pods)"

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: le-workloads-quota
  namespace: le-workloads
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  hard:
    requests.cpu: "16"
    requests.memory: 32Gi
    limits.cpu: "32"
    limits.memory: 64Gi
    pods: "100"
    services: "50"
    persistentvolumeclaims: "30"
    configmaps: "100"
    secrets: "100"
EOF

echo "    ResourceQuota applied to le-workloads"

# ─── 2. le-monitoring RESOURCE QUOTA ──────────────────────
echo "[2/4] ResourceQuota for le-monitoring (8 CPU / 16Gi / 50 pods)"

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: le-monitoring-quota
  namespace: le-monitoring
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  hard:
    requests.cpu: "8"
    requests.memory: 16Gi
    limits.cpu: "16"
    limits.memory: 32Gi
    pods: "50"
    services: "20"
    persistentvolumeclaims: "20"
    configmaps: "50"
    secrets: "50"
EOF

echo "    ResourceQuota applied to le-monitoring"

# ─── 3. le-workloads LIMIT RANGE ──────────────────────────
echo "[3/4] LimitRange defaults for le-workloads"

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: le-workloads-limits
  namespace: le-workloads
  labels:
    app.kubernetes.io/part-of: linkedeye
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

echo "    LimitRange applied to le-workloads"
echo "    Defaults: 100m/128Mi request, 500m/512Mi limit per container"

# ─── 4. le-monitoring LIMIT RANGE ─────────────────────────
echo "[4/4] LimitRange defaults for le-monitoring"

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: le-monitoring-limits
  namespace: le-monitoring
  labels:
    app.kubernetes.io/part-of: linkedeye
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

echo "    LimitRange applied to le-monitoring"

echo ""
echo "[DONE] Resource Quotas & Limit Ranges applied"
echo "  le-workloads:  16 CPU / 32Gi request, 100 pods max"
echo "  le-monitoring: 8 CPU / 16Gi request, 50 pods max"
echo "  Container defaults: 100m/128Mi request, 500m/512Mi limit"
echo ""
echo "  View quotas:"
echo "    kubectl describe resourcequota -n le-workloads"
echo "    kubectl describe resourcequota -n le-monitoring"
