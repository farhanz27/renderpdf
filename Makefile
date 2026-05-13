include .env
export

.PHONY: deploy smoke-test open-pdf

deploy:
	bash infra/deploy.sh

smoke-test:
	@echo "==> Smoke test → $(PDF_LAMBDA_URL)"
	@RESPONSE=$$(curl -sf -X POST "$(PDF_LAMBDA_URL)" \
	  -H "Content-Type: application/json" \
	  -H "X-Pdf-Secret: $(PDF_SECRET)" \
	  -d '{"html":"<html><body><h1>Smoke Test</h1></body></html>"}') || \
	  { echo "FAIL: request failed"; exit 1; }; \
	echo "$$RESPONSE"; \
	PRESIGNED_URL=$$(echo "$$RESPONSE" | jq -r '.url'); \
	if [ "$$PRESIGNED_URL" = "null" ] || [ -z "$$PRESIGNED_URL" ]; then \
	  echo "FAIL: no presigned URL in response"; exit 1; \
	fi; \
	curl -sf "$$PRESIGNED_URL" --output test.pdf && file test.pdf && echo "OK"

open-pdf:
	explorer.exe test.pdf 2>/dev/null || xdg-open test.pdf 2>/dev/null || echo "Open test.pdf manually"
