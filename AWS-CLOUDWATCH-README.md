# AWS CloudWatch Integration

## � One-Command Deployment

```bash
# Set your AWS region and cluster name
export AWS_REGION=us-west-2
export CLUSTER_NAME=your-cluster-name

# Run the deployment script
./deploy-aws-cloudwatch.sh
```

That's it! The script automatically:
1. ✅ Installs CloudWatch Observability Operator
2. ✅ Applies Application Signals annotations to all supported services
3. ✅ Configures X-Ray tracing
4. ✅ Enables Container Insights

## Prerequisites

- kubectl configured for your EKS cluster
- helm 3.x installed  
- AWS CLI configured with appropriate permissions
- OpenTelemetry Demo deployed (`kubectl apply -f kubernetes/opentelemetry-demo.yaml`)

## Verify in AWS Console

After deployment, wait 2-5 minutes then check:

- **Application Signals**: CloudWatch → Application Signals → Services
- **X-Ray Traces**: CloudWatch → X-Ray → Traces  
- **Investigations**: CloudWatch → Investigations

## Supported Services (9 total)

| Language | Services |
|----------|----------|
| Java | ad, fraud-detection |
| Python | recommendation, product-reviews, load-generator |
| Node.js | frontend, payment |
| .NET | cart, accounting |

## Need Custom Configuration?

For custom OTEL Collector setup, use the AWS config file:
```bash
export OTEL_COLLECTOR_CONFIG=./src/otel-collector/otelcol-config-aws.yml
```

This config exports to AWS X-Ray (traces), CloudWatch Metrics, and CloudWatch Logs.
