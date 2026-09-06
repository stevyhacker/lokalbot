const { test, expect } = require('@playwright/test');
const installer = 'https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg';
const origin = 'http://127.0.0.1:8793';
const viewports = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
  { width: 1280, height: 720 }
];

async function noOverflow(page) {
  const bounds = await page.evaluate(() => ({
    content: document.documentElement.scrollWidth,
    viewport: document.documentElement.clientWidth
  }));
  expect(bounds.content).toBeLessThanOrEqual(bounds.viewport);
}

async function prepareCapture(page) {
  for (const element of await page.locator('[data-reveal], .reveal').all()) {
    await element.scrollIntoViewIfNeeded();
    await expect(element).toHaveCSS('opacity', '1');
  }
  await expect.poll(() => page.locator('#app-image').evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true);
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
}

for (const viewport of viewports) {
  test(`landing layout ${viewport.width} × ${viewport.height}`, async ({ page }, info) => {
    const failures = [];
    page.on('pageerror', error => failures.push(error.message));
    await page.setViewportSize(viewport);
    await page.goto('/');
    await expect(page.getByRole('heading', { level: 1 })).toHaveAccessibleName('A memory for all your work.');
    await expect(page.locator('#app-image')).toBeVisible();
    await noOverflow(page);
    if (viewport.width === 1280) {
      const product = await page.locator('.hero-product').boundingBox();
      expect(product.y + product.height).toBeLessThanOrEqual(viewport.height);
      expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThan(5000);
    }
    await prepareCapture(page);
    expect(failures).toEqual([]);
    await page.screenshot({ path: info.outputPath(`after-${viewport.width}.png`), fullPage: true });
    await info.attach(`After ${viewport.width}`, { path: info.outputPath(`after-${viewport.width}.png`), contentType: 'image/png' });
    if (process.env.WEBSITE_BASELINE) {
      await page.goto('http://127.0.0.1:8794/');
      for (let y = 0; y < await page.evaluate(() => document.documentElement.scrollHeight); y += viewport.height) {
        await page.evaluate(y => window.scrollTo(0, y), y);
        await page.waitForTimeout(80);
      }
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.waitForTimeout(600);
      await page.screenshot({ path: info.outputPath(`before-${viewport.width}.png`), fullPage: true });
      await info.attach(`Before ${viewport.width}`, { path: info.outputPath(`before-${viewport.width}.png`), contentType: 'image/png' });
    }
  });
}

test('keyboard skip link reaches the main content', async ({ page }) => {
  await page.goto('/');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(page.locator('main')).toBeFocused();
});

test('app gallery loads each view and restores focus after the full image closes', async ({ page }) => {
  await page.goto('/');
  for (const [key, filename, title] of [
    ['recall', 'quick-recall.webp', 'Quick Recall'],
    ['write', 'cotyping.webp', 'Write'],
    ['timeline', 'timeline-workspace.webp', 'Timeline']
  ]) {
    const choice = page.locator(`[data-view="${key}"]`);
    await choice.focus();
    await page.keyboard.press('Enter');
    await expect(choice).toHaveAttribute('aria-current', 'true');
    await expect(page.locator('#app-image')).toHaveAttribute('src', `assets/screens/${filename}`);
    await expect.poll(() => page.locator('#app-image').evaluate(image => image.complete && image.naturalWidth > 0)).toBe(true);
    const fullImage = page.getByRole('link', { name: `Open the full ${title} screenshot`, exact: true });
    await fullImage.click();
    await expect(page.locator('#image-dialog')).toBeVisible();
    await expect(page.locator('#full-image')).toHaveAttribute('src', `assets/screens/${filename}`);
    await expect(page.getByRole('button', { name: 'Close screenshot', exact: true })).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(page.locator('#image-dialog')).not.toBeVisible();
    await expect(fullImage).toBeFocused();
  }
});

test('a late gallery image cannot replace the newest selection', async ({ page }) => {
  let releaseRecall;
  const gate = new Promise(resolve => { releaseRecall = resolve; });
  await page.route('**/quick-recall.webp', async route => { await gate; await route.continue(); });
  await page.goto('/');
  const pending = page.waitForResponse('**/quick-recall.webp');
  await page.locator('[data-view="recall"]').click();
  await page.locator('[data-view="write"]').click();
  await expect(page.locator('[data-view="write"]')).toHaveAttribute('aria-current', 'true');
  releaseRecall();
  await (await pending).finished();
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await expect(page.locator('#app-image')).toHaveAttribute('src', 'assets/screens/cotyping.webp');
  await expect(page.locator('[data-view="write"]')).toHaveAttribute('aria-current', 'true');
});

test('a failed gallery image keeps the usable current view', async ({ page }) => {
  await page.route('**/cotyping.webp', route => route.abort());
  await page.goto('/');
  await page.locator('[data-view="write"]').click();
  await expect(page.locator('#gallery-status')).toContainText('Couldn’t load Write');
  await expect(page.locator('#app-image')).toHaveAttribute('src', 'assets/screens/timeline-workspace.webp');
  await expect(page.locator('[data-view="timeline"]')).toHaveAttribute('aria-current', 'true');
  await expect(page.locator('#open-app')).not.toHaveClass(/is-changing/);
});

test('example recall searches across sources, handles empty results, and sends no queries', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.memory-result')).toHaveCount(3);
  const requests = [];
  page.on('request', request => requests.push(request.url()));
  await page.getByRole('button', { name: 'onboarding', exact: true }).click();
  await expect(page.locator('.memory-result')).toHaveCount(3);
  await expect(page.locator('#memory-results')).toContainText('Notes');
  await expect(page.locator('#memory-results')).toContainText('Safari');
  await expect(page.locator('#memory-results')).toContainText('Slack');
  const input = page.getByRole('searchbox', { name: 'Search the example memory' });
  await input.fill('no-matching-context');
  await input.press('Enter');
  await expect(page.locator('#result-count')).toHaveText('0 moments');
  await expect(page.locator('#memory-results')).toContainText('Try “launch”, “onboarding”, or “Friday”');
  await input.fill('');
  await expect(page.locator('.memory-result')).toHaveCount(6);
  await page.getByRole('button', { name: 'Friday', exact: true }).click();
  await expect(page.locator('.memory-result')).toHaveCount(3);
  expect(requests.filter(url => !url.endsWith('/favicon.ico') && !url.endsWith('/assets/lokalbot-icon.svg'))).toEqual([]);
});

test('source dialogs support keyboard open, Escape, outside click, and focus return', async ({ page }) => {
  await page.goto('/');
  const source = page.getByRole('button', { name: 'Open The launch checklist, Notion', exact: true });
  await source.focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('#source-dialog')).toBeVisible();
  await expect(page.locator('#source-title')).toHaveText('The launch checklist');
  await expect(page.locator('#source-text')).toContainText('Friday’s launch');
  await expect(page.getByRole('button', { name: 'Close source', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.locator('#source-dialog')).not.toBeVisible();
  await expect(source).toBeFocused();
  await source.click();
  await page.mouse.click(5, 5);
  await expect(page.locator('#source-dialog')).not.toBeVisible();
  await expect(source).toBeFocused();
});

test('network disclosure opens and closes by keyboard', async ({ page }) => {
  await page.goto('/');
  const summary = page.locator('.ownership-principles summary');
  await summary.focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('.ownership-principles details')).toHaveAttribute('open', '');
  await expect(page.locator('.ownership-principles details')).toContainText('require your approval');
  await expect(page.locator('.ownership-principles details a')).toHaveAttribute('href', 'privacy');
  await page.keyboard.press('Enter');
  await expect(page.locator('.ownership-principles details')).not.toHaveAttribute('open');
});

test('production metadata, installer links, guide routes, and existing fragments remain valid', async ({ page, request }) => {
  await page.goto('/');
  await expect(page.locator('meta[name="robots"][content*="noindex"]')).toHaveCount(0);
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', 'https://www.lokalbot.com/');
  await expect(page.locator('meta[property="og:title"]')).toHaveAttribute('content', 'LokalBot — A memory for all your work.');
  const downloads = page.locator(`a[href="${installer}"]`);
  await expect(downloads).toHaveCount(3);
  const anchors = await page.locator('a[href]').evaluateAll(links => links.map(link => link.href));
  for (const href of new Set(anchors)) {
    const url = new URL(href);
    if (url.origin !== origin) continue;
    const response = await request.get(url.pathname);
    expect(response.ok(), url.pathname).toBeTruthy();
    if (url.hash) {
      if (url.pathname === '/') await expect(page.locator(`[id="${url.hash.slice(1)}"]`)).toHaveCount(1);
      else expect(await response.text(), href).toContain(`id="${url.hash.slice(1)}"`);
    }
  }
  for (const id of ['features', 'how', 'proof', 'eviction', 'write', 'demo', 'download', 'guides', 'compare']) {
    await expect(page.locator(`[id="${id}"]`)).toHaveCount(1);
  }
  const data = JSON.parse(await page.locator('script[type="application/ld+json"]').textContent());
  const app = data['@graph'].find(item => item['@type'] === 'SoftwareApplication');
  expect(app.downloadUrl).toBe(installer);
  expect((await request.get(new URL(app.screenshot).pathname)).ok()).toBeTruthy();
});

test('no JavaScript keeps the gallery, product copy, setup, and downloads useful', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: viewports[0] });
  const page = await context.newPage();
  await page.goto(origin);
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download for Mac', exact: true })).toHaveAttribute('href', installer);
  await expect(page.locator('#recall-form')).toBeHidden();
  await expect(page.getByRole('link', { name: 'See Quick Recall in the app.', exact: true })).toBeVisible();
  await expect(page.locator('#open-app')).toHaveAttribute('href', 'assets/screens/timeline-workspace.webp');
  for (const element of await page.locator('[data-reveal]').all()) await expect(element).toHaveCSS('opacity', '1');
  await noOverflow(page);
  await page.locator('[data-view="recall"]').click();
  await expect(page).toHaveURL(/\/assets\/screens\/quick-recall.webp$/);
  await page.goto(`${origin}/lokalbot-vs-granola`);
  for (const element of await page.locator('.reveal').all()) await expect(element).toHaveCSS('opacity', '1');
  await context.close();
});

test('a blocked homepage script still leaves a usable static fallback', async ({ page }) => {
  await page.route('**/landing.js', route => route.abort());
  await page.goto('/');
  await expect(page.locator('#recall-form')).toBeHidden();
  await expect(page.getByRole('link', { name: 'See Quick Recall in the app.', exact: true })).toBeVisible();
  await expect(page.locator('#open-app')).toHaveAttribute('href', 'assets/screens/timeline-workspace.webp');
  await expect(page.getByRole('link', { name: 'Download for Mac', exact: true })).toHaveAttribute('href', installer);
});

test('reduced motion and 200% equivalent reflow remain usable', async ({ page }, info) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  // Halving the CSS viewport checks reflow equivalent to 200% zoom. This is not
  // a claim of physical-device, actual browser-zoom, or screen-reader testing.
  await page.setViewportSize({ width: 640, height: 360 });
  await page.goto('/');
  await noOverflow(page);
  await expect(page.locator('html')).toHaveCSS('scroll-behavior', 'auto');
  await expect(page.locator('.wordmark')).toHaveCSS('animation-name', 'none');
  await page.locator('[data-view="recall"]').click();
  await expect(page.locator('[data-view="recall"]')).toHaveAttribute('aria-current', 'true');
  await prepareCapture(page);
  await page.screenshot({ path: info.outputPath('200-percent-reflow.png'), fullPage: true });
  await info.attach('200% equivalent reflow', { path: info.outputPath('200-percent-reflow.png'), contentType: 'image/png' });
});

for (const route of ['guides', 'system-requirements', 'privacy', 'support', 'lokalbot-vs-granola']) {
  test(`shared page remains readable: /${route}`, async ({ page }, info) => {
    for (const viewport of [viewports[0], viewports[2]]) {
      await page.setViewportSize(viewport);
      const response = await page.goto(`/${route}`);
      expect(response.ok()).toBeTruthy();
      await expect(page.locator('h1')).toBeVisible();
      await noOverflow(page);
      await expect(page.getByRole('link', { name: 'Download', exact: true }).first()).toHaveAttribute('href', installer);
      for (const element of await page.locator('.reveal').all()) {
        await element.scrollIntoViewIfNeeded();
        await expect(element).toHaveCSS('opacity', '1');
      }
      await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
      await page.screenshot({ path: info.outputPath(`${route}-${viewport.width}.png`), fullPage: true });
    }
    if (route === 'system-requirements') {
      for (const id of ['first-memory', 'first-meeting', 'capture-defaults']) await expect(page.locator(`[id="${id}"]`)).toHaveCount(1);
      await expect(page.locator('article').first()).toContainText('v0.7.2');
    }
  });
}
