# IAM Permission Request - LinkedEye AWS Deployment
# Send this to your AWS Account Admin
# Date: 2026-03-07

---

## TO: AWS Account Administrator (Account: 654697417727)
## FROM: Rajkumar Madhu (rajkumar.madhu@finspot.in)
## SUBJECT: IAM Permission Request for LinkedEye Platform Deployment

---

Hi,

I am deploying the **LinkedEye shared ITSM/monitoring platform** on AWS (ap-south-1).
The K8s cluster and shared tools (Jenkins, ArgoCD, Harbor, Keycloak, Vault) are running,
but I need additional IAM permissions to complete the production setup.

### Current User
- **IAM User:** rajkumar.madhu@finspot.in
- **Group:** LE-Team
- **Account:** 654697417727

### Current Permissions (on LE-Team group)
- AmazonEC2FullAccess ✅
- AmazonVPCFullAccess ✅
- AmazonEKSClusterPolicy ✅
- IAMReadOnlyAccess ✅ (read-only, cannot create)

### Permissions Needed

Please add these AWS managed policies to the **LE-Team** group:

| # | Policy Name | ARN | Purpose |
|---|---|---|---|
| 1 | **IAMFullAccess** | `arn:aws:iam::aws:policy/IAMFullAccess` | Create IAM roles for EC2 instance profiles (K8s nodes need roles for EBS CSI, ECR pull, CloudWatch) |
| 2 | **AWSCertificateManagerFullAccess** | `arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess` | Request SSL certificate for `*.fs.le.santhira.com` to enable HTTPS on ALB |
| 3 | **ElasticLoadBalancingFullAccess** | `arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess` | Already have partial access, need full for HTTPS listener management |
| 4 | **AmazonRoute53FullAccess** | `arn:aws:iam::aws:policy/AmazonRoute53FullAccess` | DNS management if we move DNS to Route 53 (optional) |

### OR - Minimal Custom Policy (more secure)

If full access is not preferred, please create this custom policy and attach to LE-Team group:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "IAMRolesForLinkedEye",
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:DeleteRole",
                "iam:AttachRolePolicy",
                "iam:DetachRolePolicy",
                "iam:CreateInstanceProfile",
                "iam:DeleteInstanceProfile",
                "iam:AddRoleToInstanceProfile",
                "iam:RemoveRoleFromInstanceProfile",
                "iam:PassRole",
                "iam:CreatePolicy",
                "iam:DeletePolicy",
                "iam:GetRole",
                "iam:GetPolicy",
                "iam:ListRoles",
                "iam:ListPolicies",
                "iam:TagRole",
                "iam:TagPolicy"
            ],
            "Resource": [
                "arn:aws:iam::654697417727:role/le-*",
                "arn:aws:iam::654697417727:policy/le-*",
                "arn:aws:iam::654697417727:instance-profile/le-*"
            ]
        },
        {
            "Sid": "ACMForLinkedEye",
            "Effect": "Allow",
            "Action": [
                "acm:RequestCertificate",
                "acm:DescribeCertificate",
                "acm:ListCertificates",
                "acm:DeleteCertificate",
                "acm:AddTagsToCertificate"
            ],
            "Resource": "*"
        },
        {
            "Sid": "EFSForLinkedEye",
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:*"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:ResourceTag/Project": "LinkedEye"
                }
            }
        }
    ]
}
```

### Why These Are Needed

| Permission | Why | Impact if Not Granted |
|---|---|---|
| **IAM Roles** | EC2 nodes need instance profiles for EBS CSI driver, ECR image pull, CloudWatch logs | Cannot use EBS volumes, cannot pull from ECR, no centralized logging |
| **ACM Certificate** | HTTPS/SSL on ALB for production domains (`*.fs.le.santhira.com`) | Tools accessible only via HTTP (insecure), not suitable for production |
| **EFS** | Shared persistent storage across K8s pods (currently using node-local storage) | Data loss risk if worker node fails |

### AWS CLI Command (for admin to run)

Option 1 - Add managed policies:
```bash
aws iam attach-group-policy --group-name LE-Team --policy-arn arn:aws:iam::aws:policy/IAMFullAccess
aws iam attach-group-policy --group-name LE-Team --policy-arn arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess
```

Option 2 - Create custom policy (more secure):
```bash
aws iam create-policy --policy-name LE-Deployment-Permissions --policy-document file://le-custom-policy.json
aws iam attach-group-policy --group-name LE-Team --policy-arn arn:aws:iam::654697417727:policy/LE-Deployment-Permissions
```

Thank you,
Rajkumar Madhu
CTO / DevOps - FinSpot Technology Solutions
+91-917-677-2077
