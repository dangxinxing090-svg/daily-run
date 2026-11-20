const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1200, height: 900 } });
  try {
    await p.goto('https://superdevresources.com/neumorphism-ui-design-inspiration/', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await p.waitForTimeout(1800);
    const el = p.getByText('Fitness App UI Concept', { exact: false }).first();
    if (await el.count()) {
      await el.scrollIntoViewIfNeeded();
      await p.waitForTimeout(1400);
      await p.screenshot({ path: 'ref-fitness-neumo.jpg', type: 'jpeg', quality: 82 });
      console.log('OK ref-fitness-neumo.jpg');
    } else { console.log('NOT FOUND'); }
  } catch (e) { console.log('FAIL', e.message.slice(0, 120)); }
  await b.close();
})();
