# renderpdf

A serverless HTML-to-PDF microservice running on AWS Lambda. Send any HTML string, get back a pixel-perfect A4 PDF — rendered by a real Chromium browser.

## Tech stack

| Layer | Technology |
|---|---|
| Runtime | Node.js 20 |
| PDF engine | [Playwright](https://playwright.dev/) + [Chromium](https://github.com/Sparticuz/chromium) |
| Packaging | Docker (container Lambda) |
| Registry | Amazon ECR |
| Compute | AWS Lambda (512 MB, 30s timeout) |
| API | Amazon API Gateway HTTP API |

## How it works

1. Client POSTs an HTML string with a shared secret header
2. Lambda passes the HTML to a headless Chromium browser via Playwright
3. Chromium renders the page and exports it as an A4 PDF
4. The PDF bytes are returned base64-encoded in the response

The browser process is warm-started at module load — concurrent and repeat invocations reuse the same instance, keeping render times fast after the initial cold start.

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

Response: `application/pdf` binary (base64-encoded via API Gateway).

### Quick test

```bash
curl -X POST <api-url> \
  -H "Content-Type: application/json" \
  -H "X-Pdf-Secret: <your-secret>" \
  -d '{"html":"<html><body><h1>Hello</h1></body></html>"}' \
  --output out.pdf
```

## Security

Every request must include an `X-Pdf-Secret` header matching the `PDF_SECRET` Lambda environment variable. Missing or incorrect value returns `403 Forbidden`.

## Deploy

See [docs/deploy.md](docs/deploy.md) for full setup and deploy instructions.
