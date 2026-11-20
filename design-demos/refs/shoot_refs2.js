const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  try {
    await page.goto('https://developer.apple.com/news/?id=3m0ht22s', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2000);
    for (const [y, name] of [[1000,'ref-gentler-1.jpg'],[1900,'ref-gentler-2.jpg'],[2800,'ref-gentler-3.jpg']]) {
      await page.evaluate((yy) => window.scrollTo(0, yy), y);
      await page.waitForTimeout(1200);
      await page.screenshot({ path: name, type: 'jpeg', quality: 82 });
      console.log('OK', name);
    }
  } catch (e) { console.log('FAIL gentler', e.message.slice(0,100)); }
  try {
    await page.goto('https://www.strava.com/', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);
    await page.screenshot({ path: 'ref-strava.jpg', type: 'jpeg', quality: 80 });
    console.log('OK ref-strava.jpg');
  } catch (e) { console.log('FAIL strava', e.message.slice(0,100)); }
  await browser.close();
})();
