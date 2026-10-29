'use strict';

// Local-only Markdown -> PNG worker. Dependencies are installed by the user,
// never downloaded on invocation. Markdown arrives on stdin, not in argv/files.
const fs = require('node:fs');
const { pathToFileURL } = require('node:url');

async function loadMarked(filename = require.resolve('marked')) {
  // require.resolve follows the CommonJS export condition. When that build is
  // imported as ESM, Node may expose its exports only under `default` rather
  // than synthesizing named exports. ESM-only Marked versions use named ones.
  const namespace = await import(pathToFileURL(filename).href);
  const Marked = namespace.Marked ?? namespace.default?.Marked;
  if (typeof Marked !== 'function') {
    throw new Error('The resolved marked package does not export a Marked constructor; install marked 15+.');
  }
  return Marked;
}

async function main() {
  const { chromium } = require('playwright');
  const Marked = await loadMarked();
  const css = fs.readFileSync(require.resolve('github-markdown-css/github-markdown.css'), 'utf8');
  const request = JSON.parse(fs.readFileSync(0, 'utf8'));
  const escape = text => text.replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[c]);
  const markdown = new Marked({ gfm: true, renderer: {
    // Raw HTML is text, never active content. GFM-generated markup is retained.
    html(token) { return escape(token.text); },
    image(token) { return escape(`[image: ${token.text || ''}]`); },
  } });
  const browser = await chromium.launch({ headless: true });
  try {
    const context = await browser.newContext({
      viewport: { width: request.width, height: 600 },
      deviceScaleFactor: 1, javaScriptEnabled: false,
      colorScheme: request.dark ? 'dark' : 'light',
      serviceWorkers: 'block',
    });
    // Defense in depth: no network, local file, or remote image requests.
    await context.route('**/*', route => route.abort());
    const page = await context.newPage();
    await page.setContent(`<!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'">
      <style>${css}
      html, body { margin: 0; padding: 0; background: ${request.dark ? '#0d1117' : '#ffffff'}; }
      .markdown-body { box-sizing: border-box; padding: 24px; width: 100%;
        font-size: ${request.font_size}px; overflow-wrap: anywhere; }
      .markdown-body pre { white-space: pre-wrap; overflow-wrap: anywhere; }
      .markdown-body table { display: table; width: 100%; table-layout: fixed; }
      .markdown-body td, .markdown-body th { overflow-wrap: anywhere; }
      </style></head><body><article class="markdown-body">${await markdown.parse(request.markdown)}</article></body></html>`);
    const height = await page.locator('article').evaluate(el => Math.ceil(el.getBoundingClientRect().height));
    // Fail explicitly instead of silently truncating very large conversations.
    if (height > 100000 || height * request.width > 100000000) {
      throw new Error('Rendered chat is too large; fold more sections before rendering.');
    }
    await page.locator('article').screenshot({ path: request.output, animations: 'disabled' });
    fs.chmodSync(request.output, 0o600);
    process.stdout.write(JSON.stringify({ width: request.width, height }));
  } finally {
    await browser.close();
  }
}

module.exports = { loadMarked };

if (require.main === module) {
  main().catch(error => {
    process.stderr.write(`Codeit Markdown renderer: ${error.message}\nInstall playwright, marked (15+), github-markdown-css and the Playwright Chromium browser; see the Codeit README.\n`);
    process.exitCode = 1;
  });
}
