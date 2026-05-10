# renderpdf

AWS Lambda function that accepts an HTML string and returns a PDF. Built with Playwright + `@sparticuz/chromium`, deployed as a container image on ECR.

## How it works

- POST an HTML string to the API endpoint
- Lambda renders it with Chromium and returns a base64-encoded PDF
- Browser is warm-started at module load to avoid cold-start overhead per request

## Request

```bash
curl -X POST <api-url> \
  -H "Content-Type: application/json" \
  -H "X-Pdf-Secret: <your-secret>" \
  -d '{"html":"<html><body><h1>Hello</h1></body></html>"}' \
  --output out.pdf
```

## Security

All requests require an `X-Pdf-Secret` header matching the `PDF_SECRET` Lambda environment variable. Missing or wrong value returns `403`.

## Deploy

See [docs/deploy.md](docs/deploy.md) for full setup and deploy instructions.
