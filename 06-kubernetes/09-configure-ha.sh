#!/usr/bin/env bash
# ============================================================
# PHASE 6 — STEP 9: Configure HA for 2 Worker Nodes
# Applies HA patterns: replicas, PDB, anti-affinity, rolling
# updates, health probes for le-workloads and le-monitoring.
#
# Usage:
#   ./09-configure-ha.sh                     # Apply all HA configs
#   ./09-configure-ha.sh <client-name>       # Apply for specific client
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

CLIENT_NAME="${1:-}"

echo "============================================================"
echo " EKS HA Configuration (2-Node per Client)"
echo " Cluster: ${EKS_CLUSTER_NAME}"
echo "============================================================"

# ─── HA DEPLOYMENT TEMPLATE: le-workloads ─────────────────
echo ""
echo "[HA-1] Creating HA Deployment template for le-workloads"

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: le-app-template
  namespace: le-workloads
  labels:
    app: le-app
    tier: workload
    ha: "true"
spec:
  replicas: 2
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: le-app
  template:
    metadata:
      labels:
        app: le-app
        tier: workload
        ha: "true"
    spec:
      # Spread pods across worker nodes for HA
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - le-app
              topologyKey: kubernetes.io/hostname
      # Graceful shutdown
      terminationGracePeriodSeconds: 30
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        # Auto-restart unhealthy pods
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 20
          timeoutSeconds: 5
          failureThreshold: 3
        # Remove from service if not ready
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
          timeoutSeconds: 3
          failureThreshold: 3
EOF
echo "    HA Deployment template applied to le-workloads"

# ─── PDB: le-workloads ───────────────────────────────────
echo ""
echo "[HA-2] Creating PodDisruptionBudget for le-workloads"

cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: le-app-pdb
  namespace: le-workloads
  labels:
    app: le-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: le-app
EOF
echo "    PDB: minAvailable=1 (always 1 pod running during disruptions)"

# ─── HA DEPLOYMENT TEMPLATE: le-monitoring ────────────────
echo ""
echo "[HA-3] Creating HA Deployment template for le-monitoring"

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: le-monitor-template
  namespace: le-monitoring
  labels:
    app: le-monitor
    tier: monitoring
    ha: "true"
spec:
  replicas: 2
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: le-monitor
  template:
    metadata:
      labels:
        app: le-monitor
        tier: monitoring
        ha: "true"
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - le-monitor
              topologyKey: kubernetes.io/hostname
      terminationGracePeriodSeconds: 30
      containers:
      - name: monitor
        image: nginx:alpine
        ports:
        - containerPort: 9090
          name: metrics
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        livenessProbe:
          httpGet:
            path: /
            port: 9090
          initialDelaySeconds: 15
          periodSeconds: 20
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
EOF
echo "    HA Deployment template applied to le-monitoring"

# ─── PDB: le-monitoring ──────────────────────────────────
echo ""
echo "[HA-4] Creating PodDisruptionBudget for le-monitoring"

cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: le-monitor-pdb
  namespace: le-monitoring
  labels:
    app: le-monitor
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: le-monitor
EOF
echo "    PDB: minAvailable=1"

# ─── NETWORK POLICY: Pod-to-Pod Isolation ─────────────────
echo ""
echo "[HA-5] Creating NetworkPolicy for namespace isolation"

cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: le-workloads-default
  namespace: le-workloads
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow from same namespace
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: le-workloads
  # Allow from monitoring (for scraping)
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: le-monitoring
  egress:
  # Allow DNS
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
          kubernetes.io/metadata.name: le-workloads
  # Allow external (APIs, registries)
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.100.0.0/16
EOF
echo "    NetworkPolicy applied to le-workloads"

# ─── SERVICE with Session Affinity ────────────────────────
echo ""
echo "[HA-6] Creating HA Service for le-workloads"

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: le-app-svc
  namespace: le-workloads
  labels:
    app: le-app
spec:
  type: ClusterIP
  selector:
    app: le-app
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  # Sticky sessions for stateful apps
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 1800
EOF
echo "    Service le-app-svc with session affinity"

# ─── PRIORITY CLASS ───────────────────────────────────────
echo ""
echo "[HA-7] Creating PriorityClasses for workload scheduling"

cat <<'EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: le-critical
value: 1000000
globalDefault: false
description: "Critical LinkedEye workloads - never preempted"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: le-standard
value: 100000
globalDefault: true
description: "Standard LinkedEye workloads"
EOF
echo "    PriorityClasses: le-critical (1M), le-standard (100K default)"

# ─── TOPOLOGY SPREAD CONSTRAINTS (cluster-wide) ──────────
echo ""
echo "[HA-8] Creating topology-aware scheduling ConfigMap"

cat <<'GUIDEOF' > /tmp/le-ha-deployment-guide.yaml
# ============================================================
# LinkedEye HA Deployment Guide
# Use this as a template for ALL client workloads
# ============================================================
#
# REQUIRED for 2-node HA:
#   replicas: 2
#   podAntiAffinity: preferredDuringScheduling (soft)
#   PDB: minAvailable: 1
#   RollingUpdate: maxUnavailable: 1
#   livenessProbe + readinessProbe
#
# EXAMPLE: Deploy app for client "acme-corp"
# ============================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: le-itsm-acme-corp
  namespace: le-workloads
  labels:
    app: le-itsm
    client: acme-corp
    ha: "true"
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: le-itsm
      client: acme-corp
  template:
    metadata:
      labels:
        app: le-itsm
        client: acme-corp
        ha: "true"
    spec:
      # Schedule ONLY on this client's nodes
      nodeSelector:
        client: acme-corp
      # Spread across the 2 worker nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: le-itsm
                  client: acme-corp
              topologyKey: kubernetes.io/hostname
      # Use critical priority for ITSM
      priorityClassName: le-critical
      terminationGracePeriodSeconds: 30
      containers:
      - name: itsm
        image: harbor.finspot.in/linkedeye/itsm:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: "1"
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 30
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 3
        env:
        - name: CLIENT_NAME
          value: "acme-corp"
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: le-itsm-acme-corp-pdb
  namespace: le-workloads
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: le-itsm
      client: acme-corp
---
apiVersion: v1
kind: Service
metadata:
  name: le-itsm-acme-corp
  namespace: le-workloads
spec:
  type: ClusterIP
  selector:
    app: le-itsm
    client: acme-corp
  ports:
  - port: 80
    targetPort: 8080
GUIDEOF
echo "    HA deployment guide saved to /tmp/le-ha-deployment-guide.yaml"

# ─── SUMMARY ─────────────────────────────────────────────
echo ""
echo "============================================================"
echo "[DONE] EKS HA Configuration Applied"
echo ""
echo "  WHAT WAS CONFIGURED:"
echo "  ────────────────────"
echo "  [1] le-workloads:  HA Deployment (2 replicas, anti-affinity)"
echo "  [2] le-workloads:  PDB (minAvailable=1)"
echo "  [3] le-monitoring: HA Deployment (2 replicas, anti-affinity)"
echo "  [4] le-monitoring: PDB (minAvailable=1)"
echo "  [5] le-workloads:  NetworkPolicy (namespace isolation)"
echo "  [6] le-workloads:  Service (ClusterIP + session affinity)"
echo "  [7] PriorityClass: le-critical (1M) + le-standard (100K)"
echo "  [8] Template:      /tmp/le-ha-deployment-guide.yaml"
echo ""
echo "  HA RULES (2-node setup):"
echo "  ────────────────────────"
echo "  • replicas=2          → 1 pod per worker node"
echo "  • podAntiAffinity     → spread across nodes (soft)"
echo "  • PDB minAvailable=1  → always 1 pod alive during disruptions"
echo "  • RollingUpdate 1/1   → update one pod at a time"
echo "  • livenessProbe       → auto-restart crashed pods"
echo "  • readinessProbe      → remove unhealthy from service"
echo "  • PriorityClass       → critical pods never preempted"
echo "  • NetworkPolicy       → namespace-level isolation"
echo ""
echo "  FOR EACH NEW CLIENT:"
echo "  ─────────────────────"
echo "  1. Register 2 nodes:  ./05-setup-hybrid-nodes.sh register <client>"
echo "  2. Copy template:     cp /tmp/le-ha-deployment-guide.yaml <client>.yaml"
echo "  3. Replace acme-corp with <client-name>"
echo "  4. Apply:             kubectl apply -f <client>.yaml"
echo "============================================================"
