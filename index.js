const { chromium: playwrightChromium } = require('playwright-core');
const chromium = require('@sparticuz/chromium');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { randomUUID } = require('crypto');

const RENDER_TIMEOUT_MS = 15_000;
const MAX_HTML_BYTES = 5 * 1024 * 1024;
const PRESIGN_TTL_SECONDS = 300;

const s3 = new S3Client({});
let browserPromise = null;

function getBrowser() {
  if (!browserPromise) {
    browserPromise = (async () => {
      return playwrightChromium.launch({
        args: [...chromium.args, '--no-sandbox'],
        executablePath: await chromium.executablePath(),
        headless: true,
      });
    })().catch(err => {
      browserPromise = null;
      throw err;
    });
  }
  return browserPromise;
}

// Warm the browser at cold start — assigns the promise immediately so
// concurrent handler calls share the same launch instead of racing.
getBrowser().catch(console.error);

function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`Render timed out after ${ms}ms`)), ms)
    ),
  ]);
}

exports.handler = async (event) => {
  try {
    const secret = (event.headers || {})['x-pdf-secret'] || (event.headers || {})['X-Pdf-Secret'];
    if (!secret || secret !== process.env.PDF_SECRET) {
      return { statusCode: 403, body: JSON.stringify({ error: 'Forbidden' }) };
    }

    let body;
    try {
      body = typeof event.body === 'string' ? JSON.parse(event.body) : event.body;
    } catch {
      return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON body' }) };
    }

    const { html } = body || {};
    if (!html) {
      return { statusCode: 400, body: JSON.stringify({ error: 'Missing html field' }) };
    }
    const payloadBytes = Buffer.byteLength(html);
    if (payloadBytes > MAX_HTML_BYTES) {
      return { statusCode: 413, body: JSON.stringify({ error: 'HTML exceeds 5 MB limit' }) };
    }

    const startMs = Date.now();
    const b = await getBrowser();
    let context, page, pdfBytes;
    try {
      context = await b.newContext();
      page = await context.newPage();
      pdfBytes = await withTimeout(
        (async () => {
          await page.setContent(html, { waitUntil: 'load' });
          await page.emulateMedia({ media: 'print' });
          return page.pdf({ format: 'A4', printBackground: true });
        })(),
        RENDER_TIMEOUT_MS
      );
    } catch (renderErr) {
      // Chromium crash leaves browserPromise pointing at a dead browser — reset so
      // the next invocation gets a fresh one instead of failing immediately.
      if (!b.isConnected()) browserPromise = null;
      console.log(JSON.stringify({ event: 'render_failed', durationMs: Date.now() - startMs, payloadBytes, reason: renderErr.message }));
      throw renderErr;
    } finally {
      await page?.close().catch(() => {});
      await context?.close().catch(() => {});
    }

    const bucket = process.env.PDF_BUCKET;
    const key = `pdfs/${randomUUID()}.pdf`;
    await s3.send(new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: pdfBytes,
      ContentType: 'application/pdf',
    }));

    const url = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: bucket, Key: key }),
      { expiresIn: PRESIGN_TTL_SECONDS }
    );

    console.log(JSON.stringify({ event: 'render_complete', durationMs: Date.now() - startMs, payloadBytes }));
    return { statusCode: 200, body: JSON.stringify({ url }) };
  } catch (err) {
    console.error(JSON.stringify({ event: 'handler_error', reason: err.message }));
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
