const { chromium } = require('playwright');
const path = require('path');
// usage: node shot.js <html> <png> [w] [h] [waitMs]
(async () => {
  const [html, out, w = '1600', h = '1100', waitMs = '3500'] = process.argv.slice(2);
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto('file://' + path.resolve(html), { waitUntil: 'load', timeout: 45000 });
  await page.waitForTimeout(+waitMs);
  await page.screenshot({ path: out, fullPage: true });
  console.log('SHOT', out, 'pageerrors:', errors.length, errors.slice(0, 3).join(' | '));
  await browser.close();
})();
