#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 04: Apply Pod Security Standards (PSS)
# Labels namespaces with PSS enforcement levels:
#   le-workloads  → enforce=restricted
#   le-monitoring → enforce=baseline
#   kube-system   → enforce=privileged
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Applying Pod Security Standards to Namespaces"
echo "============================================================"

# ─── 1. le-workloads: RESTRICTED ───────────────────────────
echo "[1/3] le-workloads → restricted (strictest)"

kubectl label namespace le-workloads \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.29 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.29 \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=v1.29 \
  --overwrite

echo "    le-workloads: enforce=restricted, warn=restricted, audit=restricted"

# ─── 2. le-monitoring: BASELINE ───────────────────────────
echo "[2/3] le-monitoring → baseline (allows monitoring agents)"

kubectl label namespace le-monitoring \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.29 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.29 \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=v1.29 \
  --overwrite

echo "    le-monitoring: enforce=baseline, warn=restricted, audit=restricted"

# ─── 3. kube-system: PRIVILEGED ───────────────────────────
echo "[3/3] kube-system → privileged (system components)"

kubectl label namespace kube-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=v1.29 \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/warn-version=v1.29 \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/audit-version=v1.29 \
  --overwrite

echo "    kube-system: enforce=privileged"

echo ""
echo "[DONE] Pod Security Standards applied"
echo "  le-workloads:  restricted (no privilege escalation, no hostPath, etc.)"
echo "  le-monitoring: baseline (allows Prometheus node-exporter, etc.)"
echo "  kube-system:   privileged (system components unrestricted)"
