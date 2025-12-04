#!/bin/bash
set -e

SERVICE=$1
BRANCH=$(git rev-parse --abbrev-ref HEAD | sed 's/[^a-zA-Z0-9._-]/-/g')
COMMIT_SHORT=$(git rev-parse --short HEAD)
IMAGE_TAG="${BRANCH}-${COMMIT_SHORT}"
AWS_REGION="us-east-1"

if [ -z "$SERVICE" ]; then
  echo "Usage: $0 <loadgenerator|accountingservice|recommendationservice> [tag]"
  exit 1
fi

case $SERVICE in
  loadgenerator)
    ECR_REPO_NAME="opentelemetry-demo-loadgenerator"
    DOCKERFILE="src/load-generator/Dockerfile"
    ;;
  accountingservice)
    ECR_REPO_NAME="opentelemetry-demo-accountingservice"
    DOCKERFILE="src/accounting/Dockerfile"
    ;;
  recommendationservice)
    ECR_REPO_NAME="opentelemetry-demo-recommendationservice"
    DOCKERFILE="src/recommendation/Dockerfile"
    ;;
  *)
    echo "Invalid service. Choose: loadgenerator, accountingservice, or recommendationservice"
    exit 1
    ;;
esac

ECR_ALIAS=$(aws ecr-public describe-registries --region us-east-1 --query 'registries[0].aliases[0].name' --output text)
ECR_URI="public.ecr.aws/${ECR_ALIAS}/${ECR_REPO_NAME}"

echo "Logging into ECR Public..."
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

echo "Building ${SERVICE} image for linux/amd64..."
docker build --platform linux/amd64 -t ${ECR_REPO_NAME}:${IMAGE_TAG} -f ${DOCKERFILE} .
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_URI}:${IMAGE_TAG}
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_URI}:latest

echo "Pushing ${SERVICE} to ECR..."
docker push ${ECR_URI}:${IMAGE_TAG}
docker push ${ECR_URI}:latest

echo "Done! ${SERVICE} pushed to: ${ECR_URI}:${IMAGE_TAG}"
