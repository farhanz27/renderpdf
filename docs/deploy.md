# Deploy Guide

HTML-to-PDF AWS Lambda using Playwright + Chromium, deployed as a container image.

## Prerequisites

- AWS CLI installed and authenticated via SSO
- Docker running
- `jq` installed (`sudo apt install jq`)
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

### 2. Configure `.env`

A `.env` file in the project root is loaded automatically by `make`. It is git-ignored — never commit it.

```bash
AWS_REGION=ap-southeast-1
AWS_ACCOUNT_ID=<your 12-digit account id>
LAMBDA_ROLE_ARN=arn:aws:iam::<account>:role/renderpdf-lambda-role
PDF_SECRET=<random secret — generate with: openssl rand -hex 32>
PDF_BUCKET=<globally unique S3 bucket name, e.g. myapp-renderpdf-426315020469>

# Populated automatically after first deploy:
# PDF_LAMBDA_URL=https://<id>.execute-api.ap-southeast-1.amazonaws.com
```

### 3. Deploy

```bash
cd functions/renderpdf
make deploy
```

The deploy script will:
1. Verify Docker is running, AWS credentials are valid, and the IAM role exists
2. Create the S3 output bucket (if needed) and block public access
3. Attach an inline IAM policy granting the Lambda role `s3:PutObject` + `s3:GetObject` on the bucket
4. Authenticate Docker to ECR
5. Create the ECR repository (if needed)
6. Build and push the container image tagged with the current git commit SHA
7. Create or update the Lambda function (1536 MB memory, 30s timeout)
8. Create an API Gateway HTTP API with a catch-all route pointing to the Lambda
9. Save `PDF_LAMBDA_URL` back to `.env` automatically

### 4. Verify

```bash
make smoke-test
```

Sends a test HTML payload to the live Lambda, downloads the rendered PDF, and confirms it is a valid PDF file. Expected output ends with:
```
PDF document, version 1.4, 1 page(s)
OK
```

To open the downloaded `test.pdf`:

```bash
make open-pdf   # WSL2 / Linux
```

## Redeploying after code changes

```bash
make deploy
make smoke-test
```

Each deploy tags the image with the current git commit SHA, so rollbacks are possible by redeploying an earlier commit.

## Integrate with your app

After the first deploy, `.env` contains both values you need:

```
PDF_LAMBDA_URL=<API URL — written automatically by deploy>
PDF_SECRET=<same value you set in .env>
```

POST to `PDF_LAMBDA_URL` with the `X-Pdf-Secret` header and a JSON body containing your `html` string. The response is JSON with a `url` field — a presigned S3 link valid for 5 minutes. Fetch that URL directly to download the PDF (bypasses API Gateway, no 10 MB response limit).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: Docker is not running` | Start Docker Desktop / Docker daemon |
| `ERROR: AWS credentials not valid` | Run `aws sso login` |
| `ERROR: IAM role not found` | Run the `aws iam create-role` command in step 1 |
| `403 Forbidden` | `X-Pdf-Secret` header missing or wrong value |
| `400 Missing html field` | POST body must be JSON with an `html` key |
| `413` response | HTML input exceeds 5 MB limit — reduce inline assets |
| `{"error":"Render timed out..."}` | Page took >15s to render; simplify HTML or check for network requests |
| `url` key missing in response | Check CloudWatch logs — likely a Chromium launch error or S3 permission issue |
| Cold start slow (~15s) | First request after idle extracts Chromium and launches browser — expected |
