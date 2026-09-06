const { test, expect } = require('@playwright/test');
const fs = require('node:fs/promises');

// Comparative lab measurements only; no analytics, Lighthouse score, or field CWV claim.
test('record cold-load performance before and after', async ({ browser }, info) => {
  test.skip(!process.env.WEBSITE_BASELINE, 'The hosted workflow supplies the base revision.');
  test.setTimeout(180_000);
  const results = { conditions: 'Chromium, 1280x720, fresh context, 4x CPU, 150ms latency, 1.6Mbps download; median of 3 loads per revision', before: [], after: [] };
  for (const [label, port] of [['before', 8794], ['after', 8793]]) {
    for (let sample = 0; sample < 3; sample++) {
      const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
      const page = await context.newPage();
      const session = await context.newCDPSession(page);
      await session.send('Network.enable');
      await session.send('Network.setCacheDisabled', { cacheDisabled: true });
      await session.send('Network.emulateNetworkConditions', { offline: false, latency: 150, downloadThroughput: 200_000, uploadThroughput: 96_000 });
      await session.send('Emulation.setCPUThrottlingRate', { rate: 4 });
      await page.addInitScript(() => {
        window.labMetrics = { lcpMs: 0, cls: 0, clsWindow: 0, clsStart: 0, clsLast: 0 };
        new PerformanceObserver(list => {
          for (const entry of list.getEntries()) window.labMetrics.lcpMs = entry.startTime;
        }).observe({ type: 'largest-contentful-paint', buffered: true });
        new PerformanceObserver(list => {
          const m = window.labMetrics;
          for (const entry of list.getEntries()) {
            if (entry.hadRecentInput) continue;
            if (entry.startTime - m.clsLast > 1000 || entry.startTime - m.clsStart > 5000) {
              m.clsWindow = 0;
              m.clsStart = entry.startTime;
            }
            m.clsWindow += entry.value;
            m.clsLast = entry.startTime;
            m.cls = Math.max(m.cls, m.clsWindow);
          }
        }).observe({ type: 'layout-shift', buffered: true });
      });
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(12_000);
      const measurement = await page.evaluate(() => {
        const resources = performance.getEntriesByType('resource');
        const navigation = performance.getEntriesByType('navigation')[0];
        return {
          lcpMs: Math.round(window.labMetrics.lcpMs),
          cls: Number(window.labMetrics.cls.toFixed(4)),
          completedTransferKB: Math.round((navigation.transferSize + resources.reduce((sum, item) => sum + item.transferSize, 0)) / 1024),
          resources: resources.length,
          pageHeight: document.documentElement.scrollHeight,
          playingMedia: [...document.querySelectorAll('audio, video')].filter(media => !media.paused).length
        };
      });
      expect(measurement.lcpMs).toBeGreaterThan(0);
      expect(measurement.playingMedia).toBe(0);
      results[label].push(measurement);
      await context.close();
    }
  }
  const median = (items, key) => items.map(item => item[key]).sort((a, b) => a - b)[1];
  const keys = ['lcpMs', 'cls', 'completedTransferKB', 'resources', 'pageHeight'];
  const lines = [
    '### Website lab comparison', '', results.conditions, '',
    '| Metric | Base | PR |', '| --- | ---: | ---: |',
    ...keys.map(key => `| ${key} | ${median(results.before, key)} | ${median(results.after, key)} |`), '',
    'Transfer counts completed Resource Timing entries during the 12-second observation, including metadata requests; canceled or unfinished media transfers are excluded. This is a local hosted-runner comparison, not production field performance. Screenshots and traces are in the Website artifacts.'
  ];
  await fs.writeFile(info.outputPath('performance.json'), JSON.stringify(results, null, 2));
  await info.attach('Performance samples', { path: info.outputPath('performance.json'), contentType: 'application/json' });
  if (process.env.GITHUB_STEP_SUMMARY) await fs.appendFile(process.env.GITHUB_STEP_SUMMARY, `${lines.join('\n')}\n`);
  console.log(lines.join('\n'));
});
