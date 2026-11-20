const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1200, height: 900 } });
  const targets = [
    ['https://ww2.kombai.com/gallery/inspirations/tempo', 'ref-tempo.jpg'],
    ['https://superdevresources.com/neumorphism-ui-design-inspiration/', 'ref-neumo-gallery.jpg'],
  ];
  for (const [url, out] of targets) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await p.waitForTimeout(2200);
      await p.screenshot({ path: out, type: 'jpeg', quality: 80 });
      console.log('OK', out);
    } catch (e) { console.log('FAIL', url, e.message.slice(0, 100)); }
  }
  await b.close();
})();
