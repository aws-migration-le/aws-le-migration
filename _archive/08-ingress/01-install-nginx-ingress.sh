#!/usr/bin/env bash
# ============================================================
# PHASE 8 — Install NGINX Ingress Controller + TLS
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"

echo "============================================================"
echo " Installing NGINX Ingress Controller"
echo "============================================================"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"=internet-facing \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"=true \
  --set controller.replicaCount=2 \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=128Mi \
  --wait --timeout 10m

echo "[INGRESS-2] Installing cert-manager for TLS"
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait --timeout 10m

echo "[INGRESS-3] Creating ClusterIssuer (Let's Encrypt production)"
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: rajkumar.madhu@finspot.in
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

echo "[INGRESS-4] Creating Ingress rules for all shared tools"
NLB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

cat <<EOF | kubectl apply -f -
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: le-shared-tools-ingress
  namespace: le-cicd
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
  - hosts:
    - ${JENKINS_DOMAIN}
    - ${ARGOCD_DOMAIN}
    - ${HARBOR_DOMAIN}
    secretName: le-cicd-tls
  rules:
  - host: ${JENKINS_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jenkins
            port:
              number: 8080
  - host: ${ARGOCD_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
  - host: ${HARBOR_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: harbor-core
            port:
              number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: le-security-tools-ingress
  namespace: le-security
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
  - hosts:
    - ${KEYCLOAK_DOMAIN}
    - ${VAULT_DOMAIN}
    secretName: le-security-tls
  rules:
  - host: ${KEYCLOAK_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak
            port:
              number: 80
  - host: ${VAULT_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vault
            port:
              number: 8200
EOF

echo ""
echo "[DONE] NGINX Ingress + cert-manager + TLS ready"
echo ""
echo "  NLB Hostname: ${NLB_IP}"
echo "  Add DNS A records pointing to: ${NLB_IP}"
echo ""
echo "  ${JENKINS_DOMAIN}  → ${NLB_IP}"
echo "  ${ARGOCD_DOMAIN}   → ${NLB_IP}"
echo "  ${HARBOR_DOMAIN}   → ${NLB_IP}"
echo "  ${KEYCLOAK_DOMAIN} → ${NLB_IP}"
echo "  ${VAULT_DOMAIN}    → ${NLB_IP}"
