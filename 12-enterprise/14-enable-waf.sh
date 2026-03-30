#!/usr/bin/env bash
# ============================================================
# ENTERPRISE — STEP 14: Enable WAF on ALB
# Creates WAFv2 WebACL with 3 managed rule groups (Common,
# BadInputs, SQLi) + rate limit (2000 req/5min/IP).
# Associates with LinkedEye tools ALB.
# No dependencies — can run independently (ALB must exist).
# ============================================================
set -euo pipefail
source "$(dirname "$0")/../.env.shared"
source /tmp/le-network-ids.env 2>/dev/null || true

echo "============================================================"
echo " Enabling WAF on LinkedEye ALB"
echo "============================================================"

# ─── 1. GET ALB ARN ───────────────────────────────────────
echo "[1/3] Looking up ALB ARN"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-tools-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null)

if [ -z "${ALB_ARN}" ] || [ "${ALB_ARN}" = "None" ]; then
  echo "    [ERROR] ALB '${PROJECT}-tools-alb' not found. Deploy ALB first."
  exit 1
fi

echo "    ALB: ${ALB_ARN}"

# ─── 2. CREATE WAF WEB ACL ───────────────────────────────
echo "[2/3] Creating WAFv2 Web ACL: ${WAF_WEB_ACL_NAME}"

# Check if WAF already exists
EXISTING_ACL=$(aws wafv2 list-web-acls \
  --scope REGIONAL \
  --query "WebACLs[?Name=='${WAF_WEB_ACL_NAME}'].ARN" \
  --output text 2>/dev/null)

if [ -n "${EXISTING_ACL}" ] && [ "${EXISTING_ACL}" != "None" ] && [ "${EXISTING_ACL}" != "" ]; then
  WAF_ACL_ARN="${EXISTING_ACL}"
  echo "    Web ACL already exists: ${WAF_ACL_ARN}"
else
  WAF_ACL_ARN=$(aws wafv2 create-web-acl \
    --name "${WAF_WEB_ACL_NAME}" \
    --scope REGIONAL \
    --default-action '{"Allow": {}}' \
    --visibility-config '{
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "'"${WAF_WEB_ACL_NAME}"'"
    }' \
    --rules '[
      {
        "Name": "AWSManagedRulesCommonRuleSet",
        "Priority": 1,
        "Statement": {
          "ManagedRuleGroupStatement": {
            "VendorName": "AWS",
            "Name": "AWSManagedRulesCommonRuleSet"
          }
        },
        "OverrideAction": {"None": {}},
        "VisibilityConfig": {
          "SampledRequestsEnabled": true,
          "CloudWatchMetricsEnabled": true,
          "MetricName": "CommonRules"
        }
      },
      {
        "Name": "AWSManagedRulesKnownBadInputsRuleSet",
        "Priority": 2,
        "Statement": {
          "ManagedRuleGroupStatement": {
            "VendorName": "AWS",
            "Name": "AWSManagedRulesKnownBadInputsRuleSet"
          }
        },
        "OverrideAction": {"None": {}},
        "VisibilityConfig": {
          "SampledRequestsEnabled": true,
          "CloudWatchMetricsEnabled": true,
          "MetricName": "BadInputRules"
        }
      },
      {
        "Name": "AWSManagedRulesSQLiRuleSet",
        "Priority": 3,
        "Statement": {
          "ManagedRuleGroupStatement": {
            "VendorName": "AWS",
            "Name": "AWSManagedRulesSQLiRuleSet"
          }
        },
        "OverrideAction": {"None": {}},
        "VisibilityConfig": {
          "SampledRequestsEnabled": true,
          "CloudWatchMetricsEnabled": true,
          "MetricName": "SQLiRules"
        }
      },
      {
        "Name": "RateLimitPerIP",
        "Priority": 4,
        "Statement": {
          "RateBasedStatement": {
            "Limit": 2000,
            "AggregateKeyType": "IP"
          }
        },
        "Action": {"Block": {}},
        "VisibilityConfig": {
          "SampledRequestsEnabled": true,
          "CloudWatchMetricsEnabled": true,
          "MetricName": "RateLimitPerIP"
        }
      }
    ]' \
    --tags Key=Project,Value="${TAG_PROJECT}" Key=Environment,Value="${TAG_ENV}" \
    --query 'Summary.ARN' --output text)

  echo "    Web ACL created: ${WAF_ACL_ARN}"
fi

# ─── 3. ASSOCIATE WITH ALB ───────────────────────────────
echo "[3/3] Associating WAF with ALB"

aws wafv2 associate-web-acl \
  --web-acl-arn "${WAF_ACL_ARN}" \
  --resource-arn "${ALB_ARN}" \
  2>/dev/null || echo "    WAF may already be associated"

# ─── PERSIST ────────────────────────────────────────────────
cat >> /tmp/le-network-ids.env <<EOF
export WAF_ACL_ARN="${WAF_ACL_ARN}"
EOF

echo ""
echo "[DONE] WAF enabled on ALB"
echo "  Web ACL:    ${WAF_WEB_ACL_NAME}"
echo "  Rules:"
echo "    1. AWS Common Rule Set (OWASP Top 10)"
echo "    2. Known Bad Inputs (Log4j, etc.)"
echo "    3. SQL Injection Protection"
echo "    4. Rate Limit: 2000 req/5min per IP"
echo "  ALB:        ${ALB_ARN}"
