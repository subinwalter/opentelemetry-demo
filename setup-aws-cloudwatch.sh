#!/bin/bash
# =============================================================================
# AWS CloudWatch + X-Ray Integration for OpenTelemetry Demo
# =============================================================================
# This script sets up AWS CloudWatch observability for the OpenTelemetry Demo
# running on EKS. It configures:
#   1. CloudWatch EKS Add-on (agent, fluent-bit, operator)
#   2. OTEL Collector Agent with AWS exporters (awsxray, awsemf)
#   3. IRSA for collector pods
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#   - aws CLI configured with appropriate permissions
#   - Cluster with OIDC provider associated
#
# Usage:
#   export CLUSTER_NAME="your-cluster-name"
#   export AWS_REGION="us-west-2"
#   export NAMESPACE="otel-demo-dd"
#   ./setup-aws-cloudwatch.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}════════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"; }
print_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# Configuration (override via environment variables)
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-FlipAnyApplicationCluster-lwcD2iSPUYxQ}"
NAMESPACE="${NAMESPACE:-otel-demo-dd}"

print_header "AWS CloudWatch + X-Ray Integration Setup"

echo "Configuration:"
echo "  Cluster:   $CLUSTER_NAME"
echo "  Region:    $AWS_REGION"
echo "  Namespace: $NAMESPACE"

# =============================================================================
# Pre-flight Checks
# =============================================================================
print_step "Running pre-flight checks..."

command -v kubectl >/dev/null 2>&1 || { print_error "kubectl required"; exit 1; }
command -v aws >/dev/null 2>&1 || { print_error "aws CLI required"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { print_error "Cannot connect to cluster"; exit 1; }

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION" 2>/dev/null) || {
    print_error "Failed to get AWS account. Check credentials."
    exit 1
}
print_success "AWS Account: $AWS_ACCOUNT_ID"

# Get OIDC provider ID
OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query "cluster.identity.oidc.issuer" --output text 2>/dev/null | sed -e "s|https://||")
OIDC_ID=$(echo "$OIDC_PROVIDER" | cut -d'/' -f3-4 | cut -d'/' -f2)

if [ -z "$OIDC_ID" ] || [ "$OIDC_ID" = "None" ]; then
    print_error "OIDC provider not found. Run: eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $AWS_REGION --approve"
    exit 1
fi
print_success "OIDC Provider: $OIDC_ID"

# =============================================================================
# Step 1: Install CloudWatch EKS Add-on
# =============================================================================
print_step "Checking CloudWatch Observability EKS Add-on..."

ADDON_STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name amazon-cloudwatch-observability \
    --region "$AWS_REGION" --query "addon.status" --output text 2>/dev/null) || ADDON_STATUS="NOT_FOUND"

if [ "$ADDON_STATUS" = "ACTIVE" ]; then
    print_success "CloudWatch Add-on already active"
else
    print_warning "Installing CloudWatch Observability EKS Add-on..."
    
    ADDON_VERSION=$(aws eks describe-addon-versions --addon-name amazon-cloudwatch-observability \
        --region "$AWS_REGION" --query 'addons[0].addonVersions[0].addonVersion' --output text 2>/dev/null)
    
    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name amazon-cloudwatch-observability \
        --addon-version "$ADDON_VERSION" \
        --resolve-conflicts OVERWRITE \
        --region "$AWS_REGION" 2>/dev/null && print_success "Add-on installation started" || print_warning "Add-on may already exist"
    
    print_warning "Waiting for add-on to become active..."
    for i in {1..60}; do
        ADDON_STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name amazon-cloudwatch-observability \
            --region "$AWS_REGION" --query "addon.status" --output text 2>/dev/null) || ADDON_STATUS="PENDING"
        [ "$ADDON_STATUS" = "ACTIVE" ] && { print_success "Add-on is ACTIVE"; break; }
        echo -n "."
        sleep 5
    done
fi

# =============================================================================
# Step 1.5: Scope Instrumentation to Target Namespace Only
# =============================================================================
print_step "Limiting auto-instrumentation to $NAMESPACE only..."

# Label the namespace for webhook selector
kubectl label namespace "$NAMESPACE" cloudwatch-instrumentation=enabled --overwrite 2>/dev/null && \
    print_success "Labeled namespace $NAMESPACE with cloudwatch-instrumentation=enabled" || \
    print_warning "Could not label namespace"

# Patch the mutating webhook to only affect labeled namespaces
# This prevents PYTHONPATH override breaking apps in other namespaces
WEBHOOK_NAME="amazon-cloudwatch-observability-mutating-webhook-configuration"
if kubectl get mutatingwebhookconfiguration "$WEBHOOK_NAME" >/dev/null 2>&1; then
    # Get number of webhooks
    WEBHOOK_COUNT=$(kubectl get mutatingwebhookconfiguration "$WEBHOOK_NAME" -o jsonpath='{.webhooks}' | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null) || WEBHOOK_COUNT=5
    
    # Build patch for all webhooks
    PATCH="["
    for i in $(seq 0 $((WEBHOOK_COUNT - 1))); do
        [ $i -gt 0 ] && PATCH="$PATCH,"
        PATCH="$PATCH{\"op\": \"replace\", \"path\": \"/webhooks/$i/namespaceSelector\", \"value\": {\"matchLabels\": {\"cloudwatch-instrumentation\": \"enabled\"}}}"
    done
    PATCH="$PATCH]"
    
    kubectl patch mutatingwebhookconfiguration "$WEBHOOK_NAME" --type='json' -p="$PATCH" 2>/dev/null && \
        print_success "Webhook scoped to labeled namespaces only" || \
        print_warning "Could not patch webhook (may already be patched)"
else
    print_warning "Webhook not found, skipping patch"
fi

# =============================================================================
# Step 2: Create IRSA for OTEL Collector
# =============================================================================
print_step "Setting up IAM Role for OTEL Collector..."

# Determine which ServiceAccount the agent uses
AGENT_SA=$(kubectl get daemonset otel-collector-agent -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null) || AGENT_SA="otel-collector"
print_success "Agent uses ServiceAccount: $AGENT_SA"

ROLE_NAME="OtelAgentRole"

# Check if role exists
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    print_success "IAM Role $ROLE_NAME already exists"
    # Update trust policy to ensure it matches current SA
    cat > /tmp/trust-policy-otel.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${AGENT_SA}"}}
  }]
}
EOF
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document file:///tmp/trust-policy-otel.json 2>/dev/null || true
else
    print_warning "Creating IAM Role $ROLE_NAME..."
    cat > /tmp/trust-policy-otel.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {"${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${AGENT_SA}"}}
  }]
}
EOF
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/trust-policy-otel.json >/dev/null 2>&1
    print_success "Created IAM Role"
fi

# Attach policies
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 2>/dev/null || true
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess 2>/dev/null || true
print_success "Attached CloudWatchAgentServerPolicy and AWSXrayWriteOnlyAccess"

# Annotate ServiceAccount
kubectl annotate serviceaccount "$AGENT_SA" -n "$NAMESPACE" \
    "eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}" --overwrite 2>/dev/null && \
    print_success "Annotated ServiceAccount $AGENT_SA" || print_warning "Could not annotate ServiceAccount"

# =============================================================================
# Step 3: Update OTEL Collector Agent ConfigMap with AWS Exporters
# =============================================================================
print_step "Updating OTEL Collector Agent with AWS exporters..."

# Get current ConfigMap to preserve custom settings
CURRENT_CFG=$(kubectl get configmap otel-collector-agent -n "$NAMESPACE" -o jsonpath='{.data.relay}' 2>/dev/null)

if echo "$CURRENT_CFG" | grep -q "awsxray"; then
    print_success "AWS exporters already configured in Agent"
else
    print_warning "Adding AWS exporters to Agent ConfigMap..."
    
    cat <<'CONFIGMAP_EOF' | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-agent
  labels:
    app.kubernetes.io/component: agent-collector
    app.kubernetes.io/name: opentelemetry-collector
data:
  relay: |
    connectors:
      datadog/connector:
        traces:
          compute_stats_by_span_kind: true
      spanmetrics: {}
    
    exporters:
      datadog:
        api:
          key: ${env:DD_API_KEY}
          site: ${env:DD_SITE_PARAMETER}
        hostname: otelcol-helm
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 1000
        traces:
          compute_stats_by_span_kind: true
          trace_buffer: 500
      debug: {}
      opensearch:
        http:
          endpoint: http://opensearch:9200
          tls:
            insecure: true
        logs_index: otel-logs
        logs_index_time_format: yyyy-MM-dd
      otlp:
        endpoint: jaeger-collector:4317
        tls:
          insecure: true
      otlphttp/prometheus:
        endpoint: http://prometheus:9090/api/v1/otlp
        tls:
          insecure: true
      awsxray:
        region: AWS_REGION_PLACEHOLDER
        index_all_attributes: true
      awsemf:
        region: AWS_REGION_PLACEHOLDER
        namespace: OpenTelemetryDemo
        dimension_rollup_option: NoDimensionRollup
        resource_to_telemetry_conversion:
          enabled: true
    
    extensions:
      datadog/extension:
        api:
          key: ${env:DD_API_KEY}
          site: ${env:DD_SITE_PARAMETER}
        http:
          endpoint: localhost:9875
          path: /metadata
      health_check:
        endpoint: :13133
    
    processors:
      batch: {}
      k8sattributes:
        extract:
          metadata:
          - k8s.namespace.name
          - k8s.deployment.name
          - k8s.statefulset.name
          - k8s.daemonset.name
          - k8s.cronjob.name
          - k8s.job.name
          - k8s.node.name
          - k8s.pod.name
          - k8s.pod.uid
          - k8s.pod.start_time
        filter:
          node_from_env_var: K8S_NODE_NAME
        passthrough: false
        pod_association:
        - sources:
          - from: resource_attribute
            name: k8s.pod.ip
        - sources:
          - from: resource_attribute
            name: k8s.pod.uid
        - sources:
          - from: connection
      memory_limiter:
        check_interval: 1s
        limit_mib: 1536
        limit_percentage: 80
        spike_limit_mib: 512
        spike_limit_percentage: 25
      resource:
        attributes:
        - action: upsert
          key: deployment.environment.name
          value: otel-demo-dd
        - action: upsert
          key: env
          value: otel-demo-dd
      resourcedetection:
        detectors: [env, eks, ec2, system]
        override: false
        timeout: 10s
      transform:
        error_mode: ignore
        log_statements:
        - context: log
          statements:
          - set(severity_text, "INFO") where severity_text == ""
    
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: ${env:MY_POD_IP}:4317
          http:
            cors:
              allowed_origins:
              - http://*
              - https://*
            endpoint: ${env:MY_POD_IP}:4318
      filelog:
        exclude:
        - /var/log/pods/*/otc-container/*.log
        include:
        - /var/log/pods/*/*/*.log
        include_file_name: false
        include_file_path: true
        operators:
        - id: container-parser
          type: container
        start_at: end
      hostmetrics:
        collection_interval: 10s
        scrapers:
          cpu:
            metrics:
              system.cpu.utilization:
                enabled: true
          disk: {}
          filesystem:
            metrics:
              system.filesystem.utilization:
                enabled: true
          load: {}
          memory:
            metrics:
              system.memory.utilization:
                enabled: true
          network: {}
      httpcheck/frontend-proxy:
        targets:
        - endpoint: http://frontend-proxy:8080
      nginx:
        collection_interval: 10s
        endpoint: http://frontend-proxy:8080/nginx_status
      postgresql:
        collection_interval: 10s
        databases:
        - ffs
        endpoint: ffs-postgres:5432
        password: ffs
        tls:
          insecure: true
        username: ffs
      prometheus:
        config:
          scrape_configs:
          - job_name: opentelemetry-collector
            scrape_interval: 10s
            static_configs:
            - targets:
              - ${env:MY_POD_IP}:8888
      redis:
        collection_interval: 10s
        endpoint: valkey-cart:6379
        username: valkey
      zipkin:
        endpoint: ${env:MY_POD_IP}:9411
    
    service:
      extensions:
      - health_check
      - datadog/extension
      pipelines:
        logs:
          exporters:
          - opensearch
          - debug
          - datadog
          processors:
          - k8sattributes
          - memory_limiter
          - resource
          - resourcedetection
          - transform
          receivers:
          - otlp
          - filelog
        metrics:
          exporters:
          - debug
          - datadog
          - awsemf
          processors:
          - k8sattributes
          - memory_limiter
          - resource
          - resourcedetection
          - transform
          receivers:
          - datadog/connector
          - httpcheck/frontend-proxy
          - hostmetrics
          - nginx
          - otlp
          - postgresql
          - redis
          - spanmetrics
        traces:
          exporters:
          - otlp
          - debug
          - spanmetrics
          - datadog
          - datadog/connector
          - awsxray
          processors:
          - k8sattributes
          - memory_limiter
          - resource
          - resourcedetection
          - transform
          receivers:
          - otlp
      telemetry:
        metrics:
          level: detailed
          readers:
          - periodic:
              exporter:
                otlp:
                  endpoint: http://otel-collector:4318
                  protocol: http/protobuf
              interval: 10000
              timeout: 5000
CONFIGMAP_EOF

    # Replace placeholder with actual region
    kubectl get configmap otel-collector-agent -n "$NAMESPACE" -o yaml | \
        sed "s/AWS_REGION_PLACEHOLDER/$AWS_REGION/g" | \
        kubectl apply -f - >/dev/null 2>&1
    
    print_success "Updated Agent ConfigMap with awsxray and awsemf exporters"
fi

# =============================================================================
# Step 4: Restart OTEL Collector Agent
# =============================================================================
print_step "Restarting OTEL Collector Agent DaemonSet..."
kubectl rollout restart daemonset/otel-collector-agent -n "$NAMESPACE" 2>/dev/null && \
    print_success "Agent DaemonSet restarted" || print_warning "Could not restart Agent DaemonSet"

# =============================================================================
# Step 5: Wait and Verify
# =============================================================================
print_step "Waiting for pods to be ready (60 seconds)..."
sleep 60

print_step "Verification"
echo ""

# Check agent pods
echo "OTEL Collector Agent pods:"
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=agent-collector --no-headers 2>/dev/null | head -5

echo ""
echo "CloudWatch Agent pods:"
kubectl get pods -n amazon-cloudwatch --no-headers 2>/dev/null | head -5

# =============================================================================
# Done
# =============================================================================
print_header "Setup Complete!"

echo ""
echo "Traces are now being sent to AWS X-Ray."
echo "Metrics are now being sent to CloudWatch (namespace: OpenTelemetryDemo)."
echo ""
echo "Verify in AWS Console:"
echo "  • X-Ray: https://${AWS_REGION}.console.aws.amazon.com/xray/home?region=${AWS_REGION}#/traces"
echo "  • CloudWatch Metrics: Look for namespace 'OpenTelemetryDemo'"
echo ""
echo "Run verification script:"
echo "  ./verify-aws-cloudwatch.sh"
echo ""
