# renderpdf

A serverless HTML-to-PDF microservice running on AWS Lambda. Send any HTML string, get back a pixel-perfect A4 PDF — rendered by a real Chromium browser.

## Tech stack

| Layer | Technology |
|---|---|
| Runtime | Node.js 20 |
| PDF engine | [Playwright](https://playwright.dev/) + [Chromium](https://github.com/Sparticuz/chromium) |
| Packaging | Docker (container Lambda) |
| Registry | Amazon ECR |
| Compute | AWS Lambda (1536 MB, 30s timeout) |
| Storage | Amazon S3 (PDF output) |
| API | Amazon API Gateway HTTP API |

## How it works

1. Client POSTs an HTML string (≤ 5 MB) with a shared secret header
2. Lambda renders it with headless Chromium via Playwright (15s deadline)
3. The PDF is written to S3; a presigned download URL (5 min TTL) is returned

The browser is warm-started at module load — repeat invocations reuse the same instance. If Chromium crashes, the dead browser is detected and replaced on the next call.

## API

**POST** `<api-url>`

Headers:
```
Content-Type: application/json
X-Pdf-Secret: <your-secret>
```

Body:
```json
{ "html": "<html><body><h1>Hello</h1></body></html>" }
```

Response:
```json
{ "url": "https://s3.amazonaws.com/..." }
```

The `url` is a presigned S3 GET link valid for 5 minutes. Fetch it directly to stream the PDF without going through API Gateway.

### Quick test

```bash
make smoke-test
```

Or manually (values are in `.env`):

```bash
source .env
URL=$(curl -s -X POST "$PDF_LAMBDA_URL" \
  -H "Content-Type: application/json" \
  -H "X-Pdf-Secret: $PDF_SECRET" \
  -d '{"html":"<html><body><h1>Hello</h1></body></html>"}' \
  | jq -r '.url')
curl -s "$URL" --output out.pdf && file out.pdf
```

## Security

Every request must include an `X-Pdf-Secret` header matching the `PDF_SECRET` Lambda environment variable. Missing or incorrect value returns `403 Forbidden`.

## Deploy

See [docs/deploy.md](docs/deploy.md) for full setup and deploy instructions.
