#!/bin/bash
# AWS CloudWatch Verification Script v2.0
# Comprehensive checks for cluster state, agent health, and instrumentation status

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="${NAMESPACE:-otel-demo-dd}"
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-FlipAnyApplicationCluster-lwcD2iSPUYxQ}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

print_step() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}[CHECK]${NC} $1"; }
print_pass() { echo -e "  ${GREEN}PASS${NC} $1"; ((PASS_COUNT++)); }
print_fail() { echo -e "  ${RED}FAIL${NC} $1"; ((FAIL_COUNT++)); }
print_warn() { echo -e "  ${YELLOW}WARN${NC} $1"; ((WARN_COUNT++)); }
print_info() { echo -e "  ${BLUE}INFO${NC} $1"; }

echo "=============================================="
echo "  AWS CloudWatch Verification Report v2.0"
echo "=============================================="
echo "Date: $(date)"
echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Target Namespace: $NAMESPACE"
echo ""

# ============================================================================
# 1. Check AWS Connectivity
# ============================================================================
print_step "Checking AWS Connectivity"

if aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
    ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
    print_pass "AWS authenticated (Account: $ACCOUNT)"
else
    print_fail "AWS authentication failed"
fi

# ============================================================================
# 2. Check EKS Add-on Status
# ============================================================================
print_step "Checking EKS Add-on Status"

ADDON_STATUS=$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name amazon-cloudwatch-observability \
    --region "$AWS_REGION" \
    --query "addon.status" --output text 2>/dev/null) || ADDON_STATUS="NOT_FOUND"

if [ "$ADDON_STATUS" = "ACTIVE" ]; then
    print_pass "EKS Add-on status: ACTIVE"
    
    # Get add-on version
    ADDON_VER=$(aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name amazon-cloudwatch-observability \
        --region "$AWS_REGION" \
        --query "addon.addonVersion" --output text 2>/dev/null) || ADDON_VER="unknown"
    print_info "Add-on version: $ADDON_VER"
elif [ "$ADDON_STATUS" = "NOT_FOUND" ]; then
    print_fail "EKS Add-on NOT INSTALLED"
else
    print_fail "EKS Add-on status: $ADDON_STATUS (not healthy)"
fi

# ============================================================================
# 3. Check CloudWatch Namespace Resources
# ============================================================================
print_step "Checking amazon-cloudwatch namespace"

if kubectl get namespace amazon-cloudwatch >/dev/null 2>&1; then
    print_pass "Namespace amazon-cloudwatch exists"
else
    print_fail "Namespace amazon-cloudwatch MISSING"
fi

# ============================================================================
# 4. Check Operator Health
# ============================================================================
print_step "Checking CloudWatch Operator health"

OPERATOR_POD=$(kubectl get pods -n amazon-cloudwatch \
    -l app.kubernetes.io/name=amazon-cloudwatch-observability \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || OPERATOR_POD=""

if [ -n "$OPERATOR_POD" ]; then
    OPERATOR_STATUS=$(kubectl get pod "$OPERATOR_POD" -n amazon-cloudwatch \
        -o jsonpath='{.status.phase}' 2>/dev/null) || OPERATOR_STATUS="Unknown"
    
    if [ "$OPERATOR_STATUS" = "Running" ]; then
        print_pass "Operator Manager is Running ($OPERATOR_POD)"
    else
        print_fail "Operator Manager status: $OPERATOR_STATUS"
    fi
else
    print_fail "Operator Manager pod not found"
fi

# ============================================================================
# 5. Check CloudWatch Agent DaemonSet
# ============================================================================
print_step "Checking CloudWatch Agent DaemonSet"

AGENT_DESIRED=$(kubectl get daemonset -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent \
    -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null) || AGENT_DESIRED=0
AGENT_READY=$(kubectl get daemonset -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent \
    -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null) || AGENT_READY=0

if [ "$AGENT_DESIRED" -gt 0 ] && [ "$AGENT_READY" = "$AGENT_DESIRED" ]; then
    print_pass "CloudWatch Agent DaemonSet: $AGENT_READY/$AGENT_DESIRED pods ready"
else
    print_fail "CloudWatch Agent DaemonSet: $AGENT_READY/$AGENT_DESIRED pods ready"
    
    # Show agent pod logs if failing
    echo ""
    echo "--- Agent Pod Status ---"
    kubectl get pods -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent --no-headers 2>/dev/null
    echo ""
    echo "--- Recent Agent Logs (last 15 lines) ---"
    kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent --tail=15 --all-containers=true 2>/dev/null | head -30 || echo "Unable to fetch logs"
    echo "-------------------------"
fi

# ============================================================================
# 6. Check Fluent Bit (Logs collector)
# ============================================================================
print_step "Checking Fluent Bit DaemonSet"

FB_DESIRED=$(kubectl get daemonset -n amazon-cloudwatch -l app.kubernetes.io/name=fluent-bit \
    -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null) || FB_DESIRED=0
FB_READY=$(kubectl get daemonset -n amazon-cloudwatch -l app.kubernetes.io/name=fluent-bit \
    -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null) || FB_READY=0

if [ "$FB_DESIRED" -gt 0 ] && [ "$FB_READY" = "$FB_DESIRED" ]; then
    print_pass "Fluent Bit DaemonSet: $FB_READY/$FB_DESIRED pods ready"
else
    print_warn "Fluent Bit DaemonSet: $FB_READY/$FB_DESIRED pods ready"
fi

# ============================================================================
# 7. Check Target Namespace Annotations
# ============================================================================
print_step "Checking Namespace $NAMESPACE Annotations"

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    print_fail "Namespace $NAMESPACE does not exist"
else
    NS_ANNOTATIONS=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.annotations}' 2>/dev/null) || NS_ANNOTATIONS=""
    
    echo "$NS_ANNOTATIONS" | grep -q "instrumentation.opentelemetry.io/inject-java" && \
        print_pass "inject-java annotation present" || print_fail "inject-java annotation MISSING"
    
    echo "$NS_ANNOTATIONS" | grep -q "instrumentation.opentelemetry.io/inject-python" && \
        print_pass "inject-python annotation present" || print_fail "inject-python annotation MISSING"
    
    echo "$NS_ANNOTATIONS" | grep -q "instrumentation.opentelemetry.io/inject-nodejs" && \
        print_pass "inject-nodejs annotation present" || print_fail "inject-nodejs annotation MISSING"
    
    echo "$NS_ANNOTATIONS" | grep -q "instrumentation.opentelemetry.io/inject-dotnet" && \
        print_pass "inject-dotnet annotation present" || print_fail "inject-dotnet annotation MISSING"
fi

# ============================================================================
# 8. Check Workload Instrumentation
# ============================================================================
print_step "Checking Workload Instrumentation"

check_workload() {
    local name=$1
    local expected_lang=$2
    
    echo ""
    echo "  Service: $name ($expected_lang)"
    
    if ! kubectl get deployment "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
        print_warn "  → Deployment not found"
        return
    fi
    
    # Check deployment annotation
    DEPLOY_ANNOTATIONS=$(kubectl get deployment "$name" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null) || DEPLOY_ANNOTATIONS=""
    
    if echo "$DEPLOY_ANNOTATIONS" | grep -q "instrumentation.opentelemetry.io/inject-$expected_lang"; then
        print_pass "  → Deployment annotation present"
    else
        print_fail "  → Deployment annotation MISSING"
    fi
    
    # Get first running pod for this deployment using common label patterns
    POD_NAME=""
    for label in "app=$name" "app.kubernetes.io/name=$name" "app.kubernetes.io/component=$name"; do
        POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "$label" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || POD_NAME=""
        if [ -n "$POD_NAME" ]; then
            break
        fi
    done
    
    # Fallback: find pod by name prefix
    if [ -z "$POD_NAME" ]; then
        POD_NAME=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep "^${name}-" | head -1 | awk '{print $1}')
    fi
    
    if [ -z "$POD_NAME" ]; then
        print_warn "  → No pod found"
        return
    fi
    
    # Check for init containers
    INIT_CONTAINERS=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null) || INIT_CONTAINERS=""
    
    if echo "$INIT_CONTAINERS" | grep -qi "opentelemetry"; then
        print_pass "  → Init container injected"
    else
        print_fail "  → Init container NOT injected"
    fi
    
    # For Python, check PYTHONPATH
    if [ "$expected_lang" = "python" ]; then
        PYTHONPATH_SET=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.spec.containers[*].env[?(@.name=="PYTHONPATH")].value}' 2>/dev/null) || PYTHONPATH_SET=""
        
        if [ -n "$PYTHONPATH_SET" ]; then
            print_pass "  → PYTHONPATH set: $PYTHONPATH_SET"
        else
            print_warn "  → PYTHONPATH not set"
        fi
    fi
}

check_workload "ad" "java"
check_workload "fraud-detection" "java"
check_workload "recommendation" "python"
check_workload "frontend" "nodejs"
check_workload "payment" "nodejs"
check_workload "cart" "dotnet"
check_workload "accounting" "dotnet"

# ============================================================================
# 9. Check Application Signals in AWS
# ============================================================================
print_step "Checking Application Signals Status in AWS"

APP_SIGNALS=$(aws application-signals get-service-level-objective \
    --region "$AWS_REGION" 2>&1) || APP_SIGNALS=""

# This command will fail if no SLOs exist, but that's okay
# Just check if the API is accessible
if aws application-signals list-service-level-objectives \
    --region "$AWS_REGION" >/dev/null 2>&1; then
    print_pass "Application Signals API accessible"
else
    print_warn "Application Signals API check failed (may need more time or traffic)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=============================================="
echo "  Verification Summary"
echo "=============================================="
echo -e "  ${GREEN}PASS${NC}: $PASS_COUNT"
echo -e "  ${RED}FAIL${NC}: $FAIL_COUNT"
echo -e "  ${YELLOW}WARN${NC}: $WARN_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}Some checks failed. Please review the issues above.${NC}"
    echo ""
    echo "Common fixes:"
    echo "  1. Re-run deploy-aws-cloudwatch.sh"
    echo "  2. Wait 5-10 minutes for agents to stabilize"
    echo "  3. Check agent logs: kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent"
    exit 1
else
    echo -e "${GREEN}All critical checks passed!${NC}"
    exit 0
fi
