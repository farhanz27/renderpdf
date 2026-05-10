# Build: Playwright PDF Lambda (AWS Container Lambda)

## Goal

Build a standalone AWS Lambda function that accepts an HTML string and returns a PDF byte array. This is extracted from a Spring Boot invoicing app where Playwright/Chromium was running inside the main process. The Lambda has no database access and no business logic — it is purely an HTML-to-PDF renderer.

---

## Why container Lambda

Chromium exceeds the 250 MB zip deployment limit. The function must use a **container image** deployed to ECR.

---

## Directory structure to produce

```
renderpdf/
├── Dockerfile
├── index.js
├── package.json
├── .dockerignore
└── infra/
    ├── deploy.sh
    └── README.md
```

---

## `package.json`

- Runtime: Node.js 20
- Dependencies:
  - `playwright-core` — browser automation
  - `@sparticuz/chromium` — Lambda-compatible Chromium binary (no system deps needed)

---

## `index.js` — Lambda handler

### Request format (POST body, JSON)

```json
{ "html": "<full self-contained HTML string>" }
```

### Response format

On success:
```json
{
  "statusCode": 200,
  "headers": { "Content-Type": "application/pdf" },
  "body": "<base64-encoded PDF bytes>",
  "isBase64Encoded": true
}
```

On error:
```json
{ "statusCode": 500, "body": "{ \"error\": \"<message>\" }" }
```

### Security

The Lambda Function URL is public (`AuthType: NONE`). Protect it with a shared secret header:

- Expected header: `X-Pdf-Secret`
- Value comes from Lambda environment variable `PDF_SECRET`
- If header is missing or wrong → return `403`

### Browser lifecycle

- Initialize the Playwright browser **once at module scope** (outside the handler) so it survives warm invocations — do not launch a new browser on every invocation.
- Use `chromium.executablePath()` from `@sparticuz/chromium` as the executable path.
- Launch args: use `chromium.args` from `@sparticuz/chromium` plus `--no-sandbox`.
- Inside the handler: open a new `BrowserContext` and `Page` per request, close both after use.

### PDF options

- `page.setContent(html, { waitUntil: 'load' })`
- `page.emulateMedia({ media: 'print' })`
- `page.pdf({ format: 'A4', printBackground: true })`

### Handler logic (pseudocode)

```
1. Parse event body as JSON → { html, }
2. Check X-Pdf-Secret header against PDF_SECRET env var → 403 if mismatch
3. Validate html is present → 400 if missing
4. Open new BrowserContext + Page
5. page.setContent(html, { waitUntil: 'load' })
6. page.emulateMedia({ media: 'print' })
7. pdfBytes = page.pdf({ format: 'A4', printBackground: true })
8. Close Page + BrowserContext
9. Return 200 with base64(pdfBytes), isBase64Encoded: true
10. On any error: log error, return 500
```

---

## `Dockerfile`

- Base: `public.ecr.aws/lambda/nodejs:20`
- Copy `package.json`, run `npm install --omit=dev`
- Copy `index.js`
- `CMD ["index.handler"]`
- Do **not** install system Chromium packages — `@sparticuz/chromium` ships its own binary.

---

## `.dockerignore`

Exclude: `node_modules`, `infra/`, `*.md`

---

## `infra/deploy.sh`

A bash script that:

1. Reads variables from environment or prompts: `AWS_REGION`, `AWS_ACCOUNT_ID`, `ECR_REPO` (default: `renderpdf`), `FUNCTION_NAME` (default: `renderpdf`), `PDF_SECRET`
2. Authenticates Docker to ECR (`aws ecr get-login-password | docker login`)
3. Creates ECR repo if it doesn't exist (`aws ecr create-repository`, ignore error if exists)
4. Builds the Docker image, tags it, pushes to ECR
5. Creates or updates the Lambda function:
   - If function doesn't exist: `aws lambda create-function` with image URI, role ARN, 512 MB memory, 30s timeout, env var `PDF_SECRET`
   - If function exists: `aws lambda update-function-code` with new image URI, then wait for update to complete
6. Creates or updates a Lambda Function URL (`aws lambda create-function-url-config` or `add-permission` for public access)
7. Prints the Function URL at the end

---

## `infra/README.md`

Step-by-step manual setup guide:

### Prerequisites
- AWS CLI configured (`aws configure`)
- Docker running
- IAM role for Lambda with `AWSLambdaBasicExecutionRole` policy — provide the role ARN as `LAMBDA_ROLE_ARN`

### Steps

1. Set env vars:
   ```bash
   export AWS_REGION=ap-southeast-1
   export AWS_ACCOUNT_ID=<your account id>
   export LAMBDA_ROLE_ARN=arn:aws:iam::<account>:role/<role-name>
   export PDF_SECRET=<random secret string>
   ```

2. Run deploy script:
   ```bash
   bash infra/deploy.sh
   ```

3. Copy the printed Function URL. Set these in the Spring Boot app:
   ```
   PDF_LAMBDA_URL=<function url>
   PDF_LAMBDA_SECRET=<same secret>
   ```

### Redeploying after code changes
Re-run `bash infra/deploy.sh` — it detects the function exists and updates the image.

### Testing manually
```bash
curl -X POST <function-url> \
  -H "Content-Type: application/json" \
  -H "X-Pdf-Secret: <secret>" \
  -d '{"html":"<html><body><h1>Test</h1></body></html>"}' \
  --output test.pdf
```

---

## Constraints

- No business logic, no database, no auth — just HTML → PDF.
- The HTML string is fully self-contained (inline styles, no external URLs) — no need to handle network resources in Chromium.
- Must match current PDF output: A4, print background enabled.
- Do not use `puppeteer` — use `playwright-core` + `@sparticuz/chromium`.
- Keep handler code minimal and readable — no helper modules, everything in `index.js`.
