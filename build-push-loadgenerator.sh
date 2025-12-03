#!/bin/bash
set -e

ECR_REPO_NAME="opentelemetry-demo-loadgenerator"
AWS_REGION="us-east-1"
IMAGE_TAG="latest"

ECR_ALIAS=$(aws ecr-public describe-registries --region us-east-1 --query 'registries[0].aliases[0].name' --output text)
ECR_URI="public.ecr.aws/${ECR_ALIAS}/${ECR_REPO_NAME}"

echo "Building loadgenerator image for linux/amd64..."
docker build --platform linux/amd64 -t ${ECR_REPO_NAME}:${IMAGE_TAG} -f src/load-generator/Dockerfile .

echo "Tagging image for ECR..."
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_URI}:${IMAGE_TAG}

echo "Logging into ECR Public..."
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

echo "Pushing image to ECR..."
docker push ${ECR_URI}:${IMAGE_TAG}

echo "Done! Image pushed to: ${ECR_URI}:${IMAGE_TAG}"
