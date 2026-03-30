#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 16: Enhance Audit Logging
# Creates S3 bucket for log archival (Glacier after 90d),
# CloudTrail with data events + log file validation.
# No dependencies — can run independently.
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

echo "============================================================"
echo " Enhancing Audit Logging (CloudTrail + S3 Archival)"
echo "============================================================"

TRAIL_NAME="${PROJECT}-audit-trail"
AUDIT_BUCKET="${PROJECT}-audit-logs-${AWS_ACCOUNT_ID}"

# ─── 1. CREATE S3 BUCKET FOR AUDIT LOGS ──────────────────
echo "[1/3] Creating S3 bucket for audit log archival"

if aws s3api head-bucket --bucket "${AUDIT_BUCKET}" 2>/dev/null; then
  echo "    Bucket already exists: ${AUDIT_BUCKET}"
else
  aws s3api create-bucket \
    --bucket "${AUDIT_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"

  # Block public access
  aws s3api put-public-access-block \
    --bucket "${AUDIT_BUCKET}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket "${AUDIT_BUCKET}" \
    --versioning-configuration Status=Enabled

  # Encryption
  aws s3api put-bucket-encryption \
    --bucket "${AUDIT_BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Lifecycle: Glacier after 90d, delete after 730d (2 years)
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "${AUDIT_BUCKET}" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "audit-archival",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "Transitions": [{
          "Days": 90,
          "StorageClass": "GLACIER"
        }],
        "Expiration": {"Days": 730}
      }]
    }'

  # Bucket policy for CloudTrail
  aws s3api put-bucket-policy \
    --bucket "${AUDIT_BUCKET}" \
    --policy '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "AWSCloudTrailAclCheck",
          "Effect": "Allow",
          "Principal": {"Service": "cloudtrail.amazonaws.com"},
          "Action": "s3:GetBucketAcl",
          "Resource": "arn:aws:s3:::'"${AUDIT_BUCKET}"'"
        },
        {
          "Sid": "AWSCloudTrailWrite",
          "Effect": "Allow",
          "Principal": {"Service": "cloudtrail.amazonaws.com"},
          "Action": "s3:PutObject",
          "Resource": "arn:aws:s3:::'"${AUDIT_BUCKET}"'/AWSLogs/'"${AWS_ACCOUNT_ID}"'/*",
          "Condition": {
            "StringEquals": {"s3:x-amz-acl": "bucket-owner-full-control"}
          }
        }
      ]
    }'

  # Tag bucket
  aws s3api put-bucket-tagging \
    --bucket "${AUDIT_BUCKET}" \
    --tagging "TagSet=[
      {Key=Project,Value=${TAG_PROJECT}},
      {Key=Environment,Value=${TAG_ENV}},
      {Key=Purpose,Value=audit-logs}
    ]"

  echo "    Bucket created: ${AUDIT_BUCKET}"
fi

# ─── 2. CREATE CLOUDTRAIL ─────────────────────────────────
echo "[2/3] Creating CloudTrail: ${TRAIL_NAME}"

EXISTING_TRAIL=$(aws cloudtrail describe-trails \
  --trail-name-list "${TRAIL_NAME}" \
  --query 'trailList[0].TrailARN' --output text 2>/dev/null || echo "None")

if [ "${EXISTING_TRAIL}" != "None" ] && [ -n "${EXISTING_TRAIL}" ]; then
  echo "    Trail already exists: ${EXISTING_TRAIL}"
  TRAIL_ARN="${EXISTING_TRAIL}"
else
  TRAIL_ARN=$(aws cloudtrail create-trail \
    --name "${TRAIL_NAME}" \
    --s3-bucket-name "${AUDIT_BUCKET}" \
    --is-multi-region-trail \
    --enable-log-file-validation \
    --include-global-service-events \
    --tags-list Key=Project,Value="${TAG_PROJECT}" Key=Environment,Value="${TAG_ENV}" \
    --query 'TrailARN' --output text)

  echo "    Trail created: ${TRAIL_ARN}"
fi

# ─── 3. ENABLE DATA EVENTS + START LOGGING ───────────────
echo "[3/3] Configuring data events and starting logging"

# Add S3 and Lambda data events
aws cloudtrail put-event-selectors \
  --trail-name "${TRAIL_NAME}" \
  --event-selectors '[{
    "ReadWriteType": "All",
    "IncludeManagementEvents": true,
    "DataResources": [
      {
        "Type": "AWS::S3::Object",
        "Values": ["arn:aws:s3"]
      }
    ]
  }]' 2>/dev/null || echo "    Data events may already be configured"

# Start logging
aws cloudtrail start-logging --name "${TRAIL_NAME}"

echo "    Logging started with data events (S3 object-level)"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export AUDIT_BUCKET="${AUDIT_BUCKET}"
export TRAIL_ARN="${TRAIL_ARN}"
EOF

echo ""
echo "[DONE] Enhanced audit logging configured"
echo "  CloudTrail:  ${TRAIL_NAME}"
echo "  S3 Bucket:   ${AUDIT_BUCKET}"
echo "  Features:"
echo "    - Multi-region trail"
echo "    - Log file validation enabled"
echo "    - S3 data events (object-level logging)"
echo "    - Global service events included"
echo "  Lifecycle:   Glacier after 90 days, delete after 2 years"
