#!/bin/bash
# AWS CloudWatch One-Click Deployment Script
# This script handles all AWS CloudWatch integration deployment steps automatically.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration - SET THESE BEFORE RUNNING
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-opentelemetry-demo}"
NAMESPACE="${NAMESPACE:-otel-demo}"

echo "=============================================="
echo "  AWS CloudWatch Integration Deployment"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  AWS_REGION:   $AWS_REGION"
echo "  CLUSTER_NAME: $CLUSTER_NAME"
echo "  NAMESPACE:    $NAMESPACE"
echo ""

# Check prerequisites
print_step "Checking prerequisites..."

command -v kubectl >/dev/null 2>&1 || { print_error "kubectl required but not installed."; exit 1; }
command -v helm >/dev/null 2>&1 || { print_error "helm required but not installed."; exit 1; }
command -v aws >/dev/null 2>&1 || { print_error "aws CLI required but not installed."; exit 1; }

print_success "All prerequisites installed"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
    print_error "Failed to get AWS account ID. Check AWS credentials."
    exit 1
}
print_success "AWS Account ID: $AWS_ACCOUNT_ID"

# Step 1: Install CloudWatch Observability Operator
print_step "Installing CloudWatch Observability Operator..."

helm repo add aws-observability https://aws-observability.github.io/helm-charts 2>/dev/null || true
helm repo update aws-observability

if helm status amazon-cloudwatch-operator -n amazon-cloudwatch >/dev/null 2>&1; then
    print_warning "CloudWatch Operator already installed, upgrading..."
    helm upgrade amazon-cloudwatch-operator aws-observability/amazon-cloudwatch-observability \
        --namespace amazon-cloudwatch \
        --set region=$AWS_REGION \
        --set clusterName=$CLUSTER_NAME \
        --set containerLogs.enabled=true \
        --wait
else
    helm install amazon-cloudwatch-operator aws-observability/amazon-cloudwatch-observability \
        --namespace amazon-cloudwatch \
        --create-namespace \
        --set region=$AWS_REGION \
        --set clusterName=$CLUSTER_NAME \
        --set containerLogs.enabled=true \
        --wait
fi

print_success "CloudWatch Operator installed"

# Step 2: Create namespace if not exists
print_step "Creating namespace $NAMESPACE..."
kubectl create namespace $NAMESPACE 2>/dev/null || print_warning "Namespace already exists"

# Step 3: Apply Application Signals annotations
print_step "Applying Application Signals annotations..."

# Function to safely patch deployment
patch_deployment() {
    local name=$1
    local annotation=$2
    if kubectl get deployment $name -n $NAMESPACE >/dev/null 2>&1; then
        kubectl patch deployment $name -n $NAMESPACE -p "$annotation" 2>/dev/null && \
            echo "  ✓ $name" || echo "  ⚠ $name (already patched or error)"
    else
        echo "  - $name (not deployed yet, skipping)"
    fi
}

echo "Annotating Java services..."
patch_deployment "ad" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"true"}}}}}'
patch_deployment "fraud-detection" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"true"}}}}}'

echo "Annotating Python services..."
patch_deployment "recommendation" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-python":"true"}}}}}'
patch_deployment "product-reviews" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-python":"true"}}}}}'
patch_deployment "load-generator" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-python":"true"}}}}}'

echo "Annotating Node.js services..."
patch_deployment "frontend" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-nodejs":"true"}}}}}'
patch_deployment "payment" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-nodejs":"true"}}}}}'

echo "Annotating .NET services..."
patch_deployment "cart" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-dotnet":"true","instrumentation.opentelemetry.io/otel-dotnet-auto-runtime":"linux-musl-x64"}}}}}'
patch_deployment "accounting" '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-dotnet":"true"}}}}}'

print_success "Annotations applied"

# Step 4: Verify deployment
print_step "Verifying deployment..."

echo ""
echo "CloudWatch Operator pods:"
kubectl get pods -n amazon-cloudwatch --no-headers 2>/dev/null | head -5

echo ""
echo "=============================================="
print_success "Deployment complete!"
echo "=============================================="
echo ""
echo "Next steps:"
echo "  1. Deploy OpenTelemetry Demo (if not already):"
echo "     kubectl apply -f kubernetes/opentelemetry-demo.yaml"
echo ""
echo "  2. Wait 2-5 minutes for data to appear in CloudWatch"
echo ""
echo "  3. Verify in AWS Console:"
echo "     - CloudWatch → Application Signals → Services"
echo "     - CloudWatch → X-Ray → Traces"
echo ""
echo "  4. Enable CloudWatch Investigations for AI-powered root cause analysis"
echo ""
