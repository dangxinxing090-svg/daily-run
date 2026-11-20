const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const targets = [
    ['https://developer.apple.com/news/?id=3m0ht22s', 'ref-gentler.jpg'],
    ['https://www.apple.com/apple-fitness/', 'ref-fitness.jpg'],
  ];
  for (const [url, out] of targets) {
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await page.waitForTimeout(2500);
      await page.screenshot({ path: out, type: 'jpeg', quality: 80 });
      console.log('OK', out);
    } catch (e) { console.log('FAIL', url, e.message.slice(0, 120)); }
  }
  await browser.close();
})();
