# AWS CloudWatch + Application Signals Integration

## Prerequisites

1. **EKS Cluster** with OIDC provider enabled
2. **eksctl** installed ([installation guide](https://eksctl.io/installation/))
3. **AWS CLI** configured with admin permissions
4. **kubectl** connected to your cluster

## One-Command Deployment

```bash
export AWS_REGION=us-west-2
export CLUSTER_NAME=your-cluster-name
./deploy-aws-cloudwatch.sh
```

The script automatically:
1. Creates IAM service accounts with proper permissions (IRSA)
2. Installs CloudWatch Observability **EKS Add-on**
3. Enables Application Signals discovery
4. Annotates services for auto-instrumentation
5. Restarts pods to apply instrumentation

## After Deployment

1. **Wait 5-10 minutes** for data to appear
2. **Generate traffic**: Browse the demo app
3. **Check AWS Console**:
   - CloudWatch → Application Signals → Services
   - CloudWatch → X-Ray traces → Traces

## Manual Installation (if script fails)

1. **AWS Console** → EKS → Your Cluster → Add-ons
2. Click **Get more add-ons**
3. Select **Amazon CloudWatch Observability**
4. Configure IAM permissions when prompted
5. Install and wait for ACTIVE status

Then run:
```bash
./deploy-aws-cloudwatch.sh  # Will skip add-on, just apply annotations
```

## Troubleshooting

```bash
# Check CloudWatch agent pods
kubectl get pods -n amazon-cloudwatch

# Check agent logs
kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent

# Verify annotations on a pod
kubectl get pod -n otel-demo -l app=frontend -o jsonpath='{.items[0].metadata.annotations}'
```
