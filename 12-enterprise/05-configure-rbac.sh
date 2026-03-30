#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 05: Configure Fine-Grained RBAC
# Creates ClusterRoles and RoleBindings for:
#   le-argocd-deployer  — CRUD on workloads/monitoring namespaces
#   le-jenkins-ci       — deploy only (create/update, no delete)
#   le-prometheus-reader — cluster-wide read for metrics
#   le-client-admin     — namespace-scoped admin per client
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Configuring Fine-Grained RBAC for LinkedEye EKS"
echo "============================================================"

# ─── 1. ARGOCD DEPLOYER ────────────────────────────────────
echo "[1/4] Creating ClusterRole: le-argocd-deployer"

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: le-argocd-deployer
  labels:
    app.kubernetes.io/part-of: linkedeye
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io", "autoscaling"]
  resources:
  - deployments
  - replicasets
  - statefulsets
  - daemonsets
  - services
  - configmaps
  - secrets
  - persistentvolumeclaims
  - jobs
  - cronjobs
  - ingresses
  - networkpolicies
  - horizontalpodautoscalers
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["namespaces", "pods", "pods/log", "events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: le-argocd-deployer-workloads
  namespace: le-workloads
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: le-argocd-deployer
subjects:
- kind: ServiceAccount
  name: argocd-application-controller
  namespace: argocd
- kind: Group
  name: le-argocd-deployers
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: le-argocd-deployer-monitoring
  namespace: le-monitoring
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: le-argocd-deployer
subjects:
- kind: ServiceAccount
  name: argocd-application-controller
  namespace: argocd
- kind: Group
  name: le-argocd-deployers
  apiGroup: rbac.authorization.k8s.io
EOF

echo "    ClusterRole + RoleBindings created (le-workloads, le-monitoring)"

# ─── 2. JENKINS CI (DEPLOY ONLY) ──────────────────────────
echo "[2/4] Creating ClusterRole: le-jenkins-ci"

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: le-jenkins-ci
  labels:
    app.kubernetes.io/part-of: linkedeye
rules:
- apiGroups: ["", "apps", "batch"]
  resources:
  - deployments
  - statefulsets
  - jobs
  - configmaps
  - secrets
  - services
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: le-jenkins-ci-workloads
  namespace: le-workloads
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: le-jenkins-ci
subjects:
- kind: Group
  name: le-jenkins-ci
  apiGroup: rbac.authorization.k8s.io
EOF

echo "    ClusterRole + RoleBinding created (le-workloads only, no delete)"

# ─── 3. PROMETHEUS READER (CLUSTER-WIDE) ──────────────────
echo "[3/4] Creating ClusterRole: le-prometheus-reader"

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: le-prometheus-reader
  labels:
    app.kubernetes.io/part-of: linkedeye
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/metrics
  - nodes/proxy
  - services
  - endpoints
  - pods
  - configmaps
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: le-prometheus-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: le-prometheus-reader
subjects:
- kind: ServiceAccount
  name: prometheus-kube-prometheus-prometheus
  namespace: le-monitoring
- kind: Group
  name: le-prometheus-readers
  apiGroup: rbac.authorization.k8s.io
EOF

echo "    ClusterRole + ClusterRoleBinding created (cluster-wide read)"

# ─── 4. CLIENT ADMIN (NAMESPACE-SCOPED) ───────────────────
echo "[4/4] Creating ClusterRole: le-client-admin"

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: le-client-admin
  labels:
    app.kubernetes.io/part-of: linkedeye
rules:
- apiGroups: ["", "apps", "batch", "networking.k8s.io", "autoscaling"]
  resources: ["*"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods/exec", "pods/portforward", "pods/log"]
  verbs: ["get", "create"]
EOF

echo "    ClusterRole created (bind per-client via RoleBinding)"
echo ""
echo "    To grant a client admin access to their namespace:"
echo "      kubectl create rolebinding <client>-admin \\"
echo "        --clusterrole=le-client-admin \\"
echo "        --group=le-client-<name> \\"
echo "        --namespace=le-workloads"

echo ""
echo "[DONE] RBAC configuration applied"
echo "  le-argocd-deployer:   CRUD on workloads + monitoring"
echo "  le-jenkins-ci:        deploy-only (no delete) on workloads"
echo "  le-prometheus-reader: cluster-wide metrics read"
echo "  le-client-admin:      namespace-scoped admin (bind per client)"
