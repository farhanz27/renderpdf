#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Required env vars — set in .env (project root) or export manually:
#   AWS_REGION       e.g. ap-southeast-1
#   AWS_ACCOUNT_ID   e.g. 123456789012
#   LAMBDA_ROLE_ARN  e.g. arn:aws:iam::123456789012:role/my-lambda-role
#   PDF_SECRET       random secret string used in X-Pdf-Secret header
#   PDF_BUCKET       S3 bucket name for PDF output (e.g. my-renderpdf-output)
#
# Optional (defaults shown):
#   ECR_REPO      renderpdf
#   FUNCTION_NAME renderpdf
# ---------------------------------------------------------------------------

: "${AWS_REGION:?Set AWS_REGION}"
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${LAMBDA_ROLE_ARN:?Set LAMBDA_ROLE_ARN}"
: "${PDF_SECRET:?Set PDF_SECRET}"
: "${PDF_BUCKET:?Set PDF_BUCKET}"

ECR_REPO="${ECR_REPO:-renderpdf}"
FUNCTION_NAME="${FUNCTION_NAME:-renderpdf}"
ROLE_NAME=$(basename "${LAMBDA_ROLE_ARN}")
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "manual")
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
echo "==> Checking prerequisites"

if ! docker info > /dev/null 2>&1; then
  echo "ERROR: Docker is not running — start Docker and retry"; exit 1
fi

if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "ERROR: AWS credentials not valid — run 'aws sso login' first"; exit 1
fi

if ! aws iam get-role --role-name "${ROLE_NAME}" > /dev/null 2>&1; then
  echo "ERROR: IAM role '${ROLE_NAME}' not found — create it first (see docs/deploy.md)"; exit 1
fi

echo "    Docker OK | AWS credentials OK | IAM role OK"
echo "    Image tag: ${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# S3 bucket
# ---------------------------------------------------------------------------
echo "==> Creating S3 bucket for PDF output (ignored if already exists)"
if [ "${AWS_REGION}" = "us-east-1" ]; then
  aws s3api create-bucket \
    --bucket "${PDF_BUCKET}" \
    --region "${AWS_REGION}" 2>/dev/null || true
else
  aws s3api create-bucket \
    --bucket "${PDF_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}" 2>/dev/null || true
fi

echo "==> Blocking public access on S3 bucket"
aws s3api put-public-access-block \
  --bucket "${PDF_BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  2>/dev/null || true

# ---------------------------------------------------------------------------
# IAM inline policy
# ---------------------------------------------------------------------------
echo "==> Granting Lambda role S3 access to ${PDF_BUCKET}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "renderpdf-s3" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${PDF_BUCKET}/pdfs/*\"}]}"

# ---------------------------------------------------------------------------
# ECR + Docker
# ---------------------------------------------------------------------------
echo "==> Creating ECR repository (ignored if already exists)"
aws ecr create-repository \
  --repository-name "${ECR_REPO}" \
  --region "${AWS_REGION}" 2>/dev/null || true

echo "==> Building Docker image (${IMAGE_TAG})"
docker build --platform linux/amd64 --provenance=false -t "${ECR_REPO}:${IMAGE_TAG}" "${SCRIPT_DIR}/.."

echo "==> Tagging and pushing image"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------
echo "==> Checking if Lambda function exists"
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" &>/dev/null; then
  echo "==> Updating existing Lambda function code"
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --image-uri "${IMAGE_URI}" \
    --region "${AWS_REGION}" \
    --output text --query 'FunctionArn' > /dev/null

  echo "==> Waiting for update to complete"
  aws lambda wait function-updated \
    --function-name "${FUNCTION_NAME}" \
    --region "${AWS_REGION}"

  echo "==> Updating environment variables"
  aws lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --memory-size 1536 \
    --environment "Variables={PDF_SECRET=${PDF_SECRET},PDF_BUCKET=${PDF_BUCKET}}" \
    --region "${AWS_REGION}" \
    --output text --query 'FunctionArn' > /dev/null

  aws lambda wait function-updated \
    --function-name "${FUNCTION_NAME}" \
    --region "${AWS_REGION}"
else
  echo "==> Creating new Lambda function"
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --package-type Image \
    --code "ImageUri=${IMAGE_URI}" \
    --role "${LAMBDA_ROLE_ARN}" \
    --memory-size 1536 \
    --timeout 30 \
    --environment "Variables={PDF_SECRET=${PDF_SECRET},PDF_BUCKET=${PDF_BUCKET}}" \
    --region "${AWS_REGION}" \
    --output text --query 'FunctionArn' > /dev/null

  echo "==> Waiting for function to become active"
  aws lambda wait function-active \
    --function-name "${FUNCTION_NAME}" \
    --region "${AWS_REGION}"
fi

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------
echo "==> Configuring API Gateway HTTP API"
API_ID=$(aws apigatewayv2 get-apis \
  --region "${AWS_REGION}" \
  --query "Items[?Name=='${FUNCTION_NAME}'].ApiId" \
  --output text)

if [ -z "${API_ID}" ]; then
  echo "==> Creating new API Gateway HTTP API"
  API_ID=$(aws apigatewayv2 create-api \
    --name "${FUNCTION_NAME}" \
    --protocol-type HTTP \
    --region "${AWS_REGION}" \
    --query 'ApiId' \
    --output text)

  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "${API_ID}" \
    --integration-type AWS_PROXY \
    --integration-uri "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${FUNCTION_NAME}" \
    --payload-format-version "2.0" \
    --region "${AWS_REGION}" \
    --query 'IntegrationId' \
    --output text)

  aws apigatewayv2 create-route \
    --api-id "${API_ID}" \
    --route-key '$default' \
    --target "integrations/${INTEGRATION_ID}" \
    --region "${AWS_REGION}" \
    --output text --query 'RouteId' > /dev/null

  aws apigatewayv2 create-stage \
    --api-id "${API_ID}" \
    --stage-name '$default' \
    --auto-deploy \
    --region "${AWS_REGION}" \
    --output text --query 'StageName' > /dev/null

  aws lambda add-permission \
    --function-name "${FUNCTION_NAME}" \
    --statement-id AllowAPIGateway \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*" \
    --region "${AWS_REGION}" \
    --output text --query 'Statement' > /dev/null
else
  echo "    API Gateway already exists (${API_ID}) — skipping create"
fi

API_ENDPOINT=$(aws apigatewayv2 get-api \
  --api-id "${API_ID}" \
  --region "${AWS_REGION}" \
  --query 'ApiEndpoint' \
  --output text)

# ---------------------------------------------------------------------------
# Save API URL back to .env
# ---------------------------------------------------------------------------
if [ -f "${ENV_FILE}" ]; then
  if grep -q "^PDF_LAMBDA_URL=" "${ENV_FILE}"; then
    sed -i "s|^PDF_LAMBDA_URL=.*|PDF_LAMBDA_URL=${API_ENDPOINT}|" "${ENV_FILE}"
  else
    echo "PDF_LAMBDA_URL=${API_ENDPOINT}" >> "${ENV_FILE}"
  fi
  echo "==> PDF_LAMBDA_URL saved to .env"
fi

echo ""
echo "==> Deploy complete"
echo "    API URL : ${API_ENDPOINT}"
echo "    Image   : ${IMAGE_URI}"
echo ""
echo "Run 'make smoke-test' to verify the deployment."
