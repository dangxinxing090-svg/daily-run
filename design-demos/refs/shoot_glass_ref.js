const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 1200, height: 900 } });
  const targets = [
    ['https://www.apple.com/ios/ios-26/', 'ref-liquid-glass.jpg'],
    ['https://www.behance.net/search/projects/glassmorphism%20fitness%20app', 'ref-glass-fitness.jpg'],
  ];
  for (const [url, out] of targets) {
    try { await p.goto(url, {waitUntil:'domcontentloaded', timeout:30000}); await p.waitForTimeout(2500); await p.screenshot({path:out, type:'jpeg', quality:80}); console.log('OK', out); }
    catch(e){ console.log('FAIL', out, e.message.slice(0,80)); }
  }
  await b.close();
})();
