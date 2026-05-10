const { chromium: playwrightChromium } = require('playwright-core');
const chromium = require('@sparticuz/chromium');

let browserPromise = null;

function getBrowser() {
  if (!browserPromise) {
    browserPromise = (async () => {
      return playwrightChromium.launch({
        args: [...chromium.args, '--no-sandbox'],
        executablePath: await chromium.executablePath(),
        headless: true,
      });
    })();
  }
  return browserPromise;
}

// Warm the browser at cold start — assigns the promise immediately so
// concurrent handler calls share the same launch instead of racing.
getBrowser().catch(console.error);

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

    const b = await getBrowser();
    const context = await b.newContext();
    const page = await context.newPage();

    try {
      await page.setContent(html, { waitUntil: 'load' });
      await page.emulateMedia({ media: 'print' });
      const pdfBytes = await page.pdf({ format: 'A4', printBackground: true });

      return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/pdf' },
        body: pdfBytes.toString('base64'),
        isBase64Encoded: true,
      };
    } finally {
      await page.close();
      await context.close();
    }
  } catch (err) {
    console.error('PDF render error:', err);
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
