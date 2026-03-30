#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 11: Deploy Prometheus + Grafana
# Deploys kube-prometheus-stack via Helm to le-monitoring.
# Prometheus: 50Gi retention 30d, Grafana: NodePort 30090
# AlertManager routes to StackStorm (st2api:9101).
# Depends on: 10-apply-resource-quotas.sh (quotas first)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Deploying kube-prometheus-stack (Prometheus + Grafana)"
echo " Namespace: le-monitoring"
echo "============================================================"

# ─── 1. ADD HELM REPO ─────────────────────────────────────
echo "[1/3] Adding prometheus-community Helm repo"

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "    Helm repo ready"

# ─── 2. CREATE VALUES FILE ────────────────────────────────
echo "[2/3] Generating Helm values"

VALUES_FILE="/tmp/le-prometheus-values.yaml"
cat > "${VALUES_FILE}" <<'EOF'
# LinkedEye kube-prometheus-stack values
fullnameOverride: le-prometheus

prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "45GB"
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: "2"
        memory: 4Gi
    # Scrape all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
  config:
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'namespace', 'job']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: stackstorm
      routes:
      - receiver: stackstorm
        matchers:
        - severity =~ "critical|warning"
    receivers:
    - name: stackstorm
      webhook_configs:
      - url: 'http://st2api:9101/v1/webhooks/alertmanager'
        send_resolved: true
    - name: 'null'

grafana:
  adminPassword: LinkedEye@Grafana2026
  service:
    type: NodePort
    nodePort: 30090
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: 'LinkedEye'
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL

kubeStateMetrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

nodeExporter:
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      cpu: 200m
      memory: 128Mi
EOF

echo "    Values file created: ${VALUES_FILE}"

# ─── 3. INSTALL VIA HELM ──────────────────────────────────
echo "[3/3] Installing kube-prometheus-stack"

helm upgrade --install le-prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace le-monitoring \
  --create-namespace \
  --values "${VALUES_FILE}" \
  --timeout 10m \
  --wait

echo ""
echo "[DONE] kube-prometheus-stack deployed"
echo "  Namespace:    le-monitoring"
echo "  Prometheus:   50Gi storage, 30d retention"
echo "  Grafana:      NodePort 30090"
echo "  AlertManager: webhooks → st2api:9101"
echo ""
echo "  Access Grafana:"
echo "    URL:      http://<node-ip>:30090"
echo "    User:     admin"
echo "    Password: LinkedEye@Grafana2026"
echo ""
echo "  View pods:"
echo "    kubectl get pods -n le-monitoring"
