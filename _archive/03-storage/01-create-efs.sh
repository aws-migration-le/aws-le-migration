#!/usr/bin/env bash
# ============================================================
# PHASE 3 — EFS Shared Storage for Kubernetes PVs
# Used by: Harbor, Vault, Jenkins (shared data)
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " EFS Setup — Shared Persistent Volumes for K8s"
echo "============================================================"

# ─── CREATE EFS FILESYSTEM ───────────────────────────────────
echo "[EFS-1] Creating EFS Filesystem"
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value="${PROJECT}-k8s-efs" \
         Key=Project,Value="${TAG_PROJECT}" \
         Key=Environment,Value="${TAG_ENV}" \
  --region "${AWS_REGION}" \
  --query 'FileSystemId' --output text)

echo "    EFS: ${EFS_ID}"
echo "    Waiting for EFS to become available..."

# Wait until available
while true; do
  STATUS=$(aws efs describe-file-systems --file-system-id "${EFS_ID}" \
    --query 'FileSystems[0].LifeCycleState' --output text)
  [[ "${STATUS}" == "available" ]] && break
  echo "    Status: ${STATUS} — waiting 5s..."
  sleep 5
done
echo "    EFS is available"

# ─── MOUNT TARGETS ───────────────────────────────────────────
echo "[EFS-2] Creating mount target in Private AZ1"
MT_AZ1=$(aws efs create-mount-target \
  --file-system-id "${EFS_ID}" \
  --subnet-id "${STORAGE_SUBNET_AZ1}" \
  --security-groups "${SG_EFS}" \
  --query 'MountTargetId' --output text)

echo "[EFS-3] Creating mount target in Private AZ2"
MT_AZ2=$(aws efs create-mount-target \
  --file-system-id "${EFS_ID}" \
  --subnet-id "${STORAGE_SUBNET_AZ2}" \
  --security-groups "${SG_EFS}" \
  --query 'MountTargetId' --output text)

echo "    Mount Target AZ1: ${MT_AZ1}"
echo "    Mount Target AZ2: ${MT_AZ2}"

# ─── EFS ACCESS POINT PER NAMESPACE ─────────────────────────
echo "[EFS-4] Creating EFS access points per K8s namespace"

for NS in le-cicd le-security le-monitoring le-data; do
  AP_ID=$(aws efs create-access-point \
    --file-system-id "${EFS_ID}" \
    --posix-user Uid=1000,Gid=1000 \
    --root-directory "Path=/${NS},CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
    --tags Key=Name,Value="${PROJECT}-efs-ap-${NS}" \
           Key=Namespace,Value="${NS}" \
    --query 'AccessPointId' --output text)
  echo "    AccessPoint for ${NS}: ${AP_ID}"
  echo "export EFS_AP_${NS//-/_}=\"${AP_ID}\"" >> /tmp/le-network-ids.env
done

cat >> /tmp/le-network-ids.env <<EOF
export EFS_ID="${EFS_ID}"
export EFS_DNS="${EFS_ID}.efs.${AWS_REGION}.amazonaws.com"
EOF

echo ""
echo "[DONE] EFS ready"
echo "  EFS ID:  ${EFS_ID}"
echo "  DNS:     ${EFS_ID}.efs.${AWS_REGION}.amazonaws.com"
echo ""
echo "  NEXT: Use this DNS in K8s PersistentVolumes or EFS CSI driver"
