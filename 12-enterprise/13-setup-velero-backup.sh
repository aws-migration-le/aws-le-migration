#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 13: Setup Velero Backup
# Creates encrypted S3 bucket, IRSA role, installs Velero via
# Helm, creates daily 2 AM backup schedule (30-day retention)
# for le-workloads + le-monitoring namespaces.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env

echo "============================================================"
echo " Setting Up Velero Backup"
echo " Cluster: ${EKS_CLUSTER_NAME}"
echo "============================================================"

VELERO_NS="velero"
VELERO_ROLE_NAME="${PROJECT}-velero-irsa-role"

# ─── 1. CREATE ENCRYPTED S3 BUCKET ────────────────────────
echo "[1/4] Creating encrypted S3 bucket for backups"

# Check if bucket already exists
if aws s3api head-bucket --bucket "${VELERO_BUCKET}" 2>/dev/null; then
  echo "    Bucket already exists: ${VELERO_BUCKET}"
else
  aws s3api create-bucket \
    --bucket "${VELERO_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"

  # Enable encryption
  aws s3api put-bucket-encryption \
    --bucket "${VELERO_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms",
          "KMSMasterKeyID": "'"${KMS_EBS_KEY_ARN}"'"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Block public access
  aws s3api put-public-access-block \
    --bucket "${VELERO_BUCKET}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "${VELERO_BUCKET}" \
    --versioning-configuration Status=Enabled

  # Lifecycle: transition to Glacier after 90 days, delete after 365
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "${VELERO_BUCKET}" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "velero-lifecycle",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "Transitions": [{
          "Days": 90,
          "StorageClass": "GLACIER"
        }],
        "Expiration": {"Days": 365}
      }]
    }'

  # Tag bucket
  aws s3api put-bucket-tagging \
    --bucket "${VELERO_BUCKET}" \
    --tagging "TagSet=[
      {Key=Project,Value=${TAG_PROJECT}},
      {Key=Environment,Value=${TAG_ENV}},
      {Key=Purpose,Value=velero-backups}
    ]"

  echo "    Bucket created: ${VELERO_BUCKET}"
  echo "    Encryption: KMS (${KMS_EBS_KEY_ARN})"
fi

# ─── 2. CREATE IRSA ROLE FOR VELERO ───────────────────────
echo "[2/4] Creating IRSA role for Velero"

OIDC_URL=$(aws eks describe-cluster \
  --name "${EKS_CLUSTER_NAME}" \
  --query 'cluster.identity.oidc.issuer' --output text)
OIDC_ID=$(echo "${OIDC_URL}" | sed 's|https://||')

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ID}:aud": "sts.amazonaws.com",
        "${OIDC_ID}:sub": "system:serviceaccount:${VELERO_NS}:velero-server"
      }
    }
  }]
}
EOF
)

VELERO_ROLE_ARN=$(aws iam create-role \
  --role-name "${VELERO_ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --tags Key=Project,Value="${TAG_PROJECT}" Key=Environment,Value="${TAG_ENV}" \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "${VELERO_ROLE_NAME}" --query 'Role.Arn' --output text)

# Attach inline policy for S3 + EC2 (volume snapshots)
aws iam put-role-policy \
  --role-name "${VELERO_ROLE_NAME}" \
  --policy-name "${PROJECT}-velero-policy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ],
        "Resource": [
          "arn:aws:s3:::'"${VELERO_BUCKET}"'",
          "arn:aws:s3:::'"${VELERO_BUCKET}"'/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ],
        "Resource": "'"${KMS_EBS_KEY_ARN}"'"
      }
    ]
  }'

echo "    Role: ${VELERO_ROLE_ARN}"

# ─── 3. INSTALL VELERO VIA HELM ───────────────────────────
echo "[3/4] Installing Velero via Helm"

helm repo add vmware-tanzu \
  https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install velero vmware-tanzu/velero \
  --namespace "${VELERO_NS}" \
  --create-namespace \
  --set configuration.backupStorageLocation[0].name=default \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket="${VELERO_BUCKET}" \
  --set configuration.backupStorageLocation[0].config.region="${AWS_REGION}" \
  --set configuration.volumeSnapshotLocation[0].name=default \
  --set configuration.volumeSnapshotLocation[0].provider=aws \
  --set configuration.volumeSnapshotLocation[0].config.region="${AWS_REGION}" \
  --set serviceAccount.server.name=velero-server \
  --set serviceAccount.server.annotations."eks\.amazonaws\.com/role-arn"="${VELERO_ROLE_ARN}" \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.9.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --set resources.limits.cpu=500m \
  --set resources.limits.memory=512Mi \
  --timeout 5m \
  --wait

echo "    Velero installed in namespace: ${VELERO_NS}"

# ─── 4. CREATE BACKUP SCHEDULES ───────────────────────────
echo "[4/4] Creating daily backup schedules"

# Wait for Velero CRDs
sleep 5

kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: le-daily-workloads
  namespace: ${VELERO_NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
    - le-workloads
    ttl: 720h0m0s
    storageLocation: default
    volumeSnapshotLocations:
    - default
---
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: le-daily-monitoring
  namespace: ${VELERO_NS}
  labels:
    app.kubernetes.io/part-of: linkedeye
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
    - le-monitoring
    ttl: 720h0m0s
    storageLocation: default
    volumeSnapshotLocations:
    - default
EOF

echo "    Schedules created: daily at 02:00 UTC, 30-day retention"

echo ""
echo "[DONE] Velero backup system deployed"
echo "  S3 Bucket:   ${VELERO_BUCKET} (KMS encrypted)"
echo "  Schedules:   daily 02:00 UTC (le-workloads + le-monitoring)"
echo "  Retention:   30 days (S3 lifecycle: Glacier after 90d)"
echo "  Role:        ${VELERO_ROLE_ARN}"
echo ""
echo "  Manual backup:"
echo "    velero backup create manual-backup --include-namespaces le-workloads"
echo "  Restore:"
echo "    velero restore create --from-backup <backup-name>"
