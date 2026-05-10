#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Required env vars (set before running or export them in your shell):
#   AWS_REGION       e.g. ap-southeast-1
#   AWS_ACCOUNT_ID   e.g. 123456789012
#   LAMBDA_ROLE_ARN  e.g. arn:aws:iam::123456789012:role/my-lambda-role
#   PDF_SECRET       random secret string used in X-Pdf-Secret header
#
# Optional (defaults shown):
#   ECR_REPO      renderpdf
#   FUNCTION_NAME renderpdf
# ---------------------------------------------------------------------------

: "${AWS_REGION:?Set AWS_REGION}"
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${LAMBDA_ROLE_ARN:?Set LAMBDA_ROLE_ARN}"
: "${PDF_SECRET:?Set PDF_SECRET}"

ECR_REPO="${ECR_REPO:-renderpdf}"
FUNCTION_NAME="${FUNCTION_NAME:-renderpdf}"
IMAGE_TAG="latest"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "==> Authenticating Docker to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Creating ECR repository (ignored if already exists)"
aws ecr create-repository \
  --repository-name "${ECR_REPO}" \
  --region "${AWS_REGION}" 2>/dev/null || true

echo "==> Building Docker image"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build --platform linux/amd64 --provenance=false -t "${ECR_REPO}:${IMAGE_TAG}" "${SCRIPT_DIR}/.."

echo "==> Tagging and pushing image"
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}"

IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"

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

  echo "==> Updating environment variable"
  aws lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --environment "Variables={PDF_SECRET=${PDF_SECRET}}" \
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
    --memory-size 512 \
    --timeout 30 \
    --environment "Variables={PDF_SECRET=${PDF_SECRET}}" \
    --region "${AWS_REGION}" \
    --output text --query 'FunctionArn' > /dev/null

  echo "==> Waiting for function to become active"
  aws lambda wait function-active \
    --function-name "${FUNCTION_NAME}" \
    --region "${AWS_REGION}"
fi

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

echo ""
echo "==> Deploy complete. API URL:"
aws apigatewayv2 get-api \
  --api-id "${API_ID}" \
  --region "${AWS_REGION}" \
  --query 'ApiEndpoint' \
  --output text
