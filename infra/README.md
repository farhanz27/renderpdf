# renderpdf — Deploy Guide

HTML-to-PDF AWS Lambda using Playwright + Chromium, deployed as a container image.

## Prerequisites

- AWS CLI installed and authenticated via SSO
- Docker running
- IAM role for Lambda with `AWSLambdaBasicExecutionRole` policy attached — you need its ARN

### Set up AWS SSO (one-time)

1. Go to **AWS Console (as root) → IAM Identity Center → Enable**
2. **Permission sets → Create permission set → AdministratorAccess**
3. **Users → Add user** (fill in email, activate via the email invite)
4. **AWS accounts → select account → Assign users → select user → select AdministratorAccess**

Then configure the CLI:

```bash
aws configure sso
# SSO start URL:  https://d-xxxxxxxxxx.awsapps.com/start  (from Identity Center dashboard)
# SSO region:     ap-southeast-1
# SSO role name:  AdministratorAccess
# Profile name:   default
```

### Log in (each session)

```bash
aws sso login
aws sts get-caller-identity   # verify — should show your account ID
```

## One-time setup

### 1. Create the IAM role (if you don't have one)

```bash
aws iam create-role \
  --role-name renderpdf-lambda-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"lambda.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }'

aws iam attach-role-policy \
  --role-name renderpdf-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
```

### 2. Set environment variables

```bash
export AWS_REGION=ap-southeast-1
export AWS_ACCOUNT_ID=<your 12-digit account id>
export LAMBDA_ROLE_ARN=arn:aws:iam::<account>:role/renderpdf-lambda-role
export PDF_SECRET=<random secret string>
```

### 3. Run the deploy script

```bash
bash infra/deploy.sh
```

The script will:
1. Authenticate Docker to ECR
2. Create the ECR repository (if needed)
3. Build and push the container image
4. Create or update the Lambda function (512 MB memory, 30s timeout)
5. Create an API Gateway HTTP API with a catch-all route pointing to the Lambda
6. Print the API URL

## Redeploying after code changes

Re-run `bash infra/deploy.sh` — it detects the existing function and updates only the image.

## Integrate with Spring Boot

Set these in your Spring Boot app (environment or `.env`):

```
PDF_LAMBDA_URL=<API URL printed by deploy script>
PDF_LAMBDA_SECRET=<same PDF_SECRET value>
```

## Testing manually

```bash
curl -X POST <api-url> \
  -H "Content-Type: application/json" \
  -H "X-Pdf-Secret: <your PDF_SECRET>" \
  -d '{"html":"<html><body><h1>Test</h1></body></html>"}' \
  --output test.pdf && file test.pdf
```

Expected output: `PDF document, version 1.4, 1 page(s)`

Open the PDF (WSL2):
```bash
explorer.exe test.pdf
```

Open the PDF (Linux):
```bash
xdg-open test.pdf
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `403 Forbidden` | `X-Pdf-Secret` header missing or wrong value |
| `400 Missing html field` | POST body must be JSON with an `html` key |
| Response is JSON not PDF | Check CloudWatch logs — likely a Chromium launch error |
| Lambda timeout | Increase timeout beyond 30s; check CloudWatch logs |
| Cold start slow (~15s) | First request after idle extracts Chromium and launches browser — expected |
