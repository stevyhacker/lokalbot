const { test, expect } = require('@playwright/test');
const installer = 'https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg';
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

for (const viewport of viewports) {
  test(`landing layout ${viewport.width} × ${viewport.height}`, async ({ page }, info) => {
    await page.setViewportSize(viewport);
    await page.goto('/');
    await expect(page.locator('.intro__crop img')).toBeVisible();
    await expect(page.locator('.intro__crop img')).toHaveJSProperty('complete', true);
    await expect(page.locator('.intro__result figcaption')).toContainText('Assigned to Me · Source: 00:26');
    await noOverflow(page);
    if (viewport.width === 1280) {
      const result = await page.locator('.intro__result').boundingBox();
      expect(result.y + result.height).toBeLessThanOrEqual(viewport.height);
      expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThanOrEqual(7000);
    }
    await page.screenshot({ path: info.outputPath(`after-${viewport.width}.png`), fullPage: true });
    await info.attach(`After ${viewport.width}`, { path: info.outputPath(`after-${viewport.width}.png`), contentType: 'image/png' });
    if (process.env.WEBSITE_BASELINE) {
      await page.goto('http://127.0.0.1:8794/');
      // Trigger the old page's lazy images and reveals before the reference capture.
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

test('mobile menu supports focus, Escape, links, and resizing', async ({ page }) => {
  await page.setViewportSize(viewports[0]);
  await page.goto('/');
  const menu = page.locator('.nav-toggle');
  const nav = page.getByRole('navigation', { name: 'Primary', exact: true });
  await expect(nav).toBeHidden();
  await menu.click();
  await expect(menu).toHaveAttribute('aria-expanded', 'true');
  await expect(nav.getByRole('link', { name: 'Product', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(nav).toBeHidden();
  await expect(menu).toBeFocused();
  await menu.click();
  await nav.getByRole('link', { name: 'Privacy', exact: true }).click();
  await expect(page).toHaveURL(/#proof$/);
  await expect(page.locator('#proof')).toBeFocused();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
  await page.setViewportSize(viewports[2]);
  await expect(nav).toBeVisible();
  await expect(menu).toBeHidden();
  await page.setViewportSize(viewports[0]);
  await expect(nav).toBeHidden();
});

test('autocomplete preserves backward navigation and supports accept, dismiss, and exit', async ({ page }) => {
  await page.goto('/');
  const disclosure = page.locator('.writing-demo > summary');
  await disclosure.click();
  const input = page.locator('#ctInput');
  await input.focus();
  const initial = await input.inputValue();
  await page.keyboard.press('Shift+Tab');
  await expect(input).toHaveValue(initial);
  await expect(disclosure).toBeFocused();
  await input.focus();
  await page.keyboard.press('Tab');
  await expect(input).toHaveValue(`${initial} our`);
  await expect(input).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(page.locator('#ctGhost')).toHaveText('');
  await page.keyboard.press('Tab');
  await expect(input).not.toBeFocused();
  await expect(input).toHaveValue(`${initial} our`);
});

test('FAQ opens by keyboard and explains the downloadable release', async ({ page }) => {
  await page.goto('/');
  const summary = page.getByText('What gets recorded by default?', { exact: true });
  await summary.focus();
  await page.keyboard.press('Enter');
  const answer = page.locator('.landing-faq details').filter({ has: summary });
  await expect(answer).toHaveAttribute('open', '');
  await expect(answer).toContainText('v0.7.2');
  await expect(answer).toContainText('automatic meeting detection');
  await expect(answer).toContainText('macOS permissions');
  await page.keyboard.press('Enter');
  await expect(answer).not.toHaveAttribute('open');
});

test('download CTAs use the installer and retain setup, release, and legacy destinations', async ({ page, request }) => {
  await page.goto('/');
  const downloads = page.getByRole('link', { name: /^Download( for macOS)?$/ });
  await expect(downloads).toHaveCount(3);
  for (const link of await downloads.all()) await expect(link).toHaveAttribute('href', installer);
  await expect(page.getByRole('link', { name: 'Release notes and all downloads' })).toHaveAttribute('href', /\/releases$/);
  const anchors = await page.locator('a[href]').evaluateAll(links => links.map(link => link.href));
  for (const href of new Set(anchors)) {
    const url = new URL(href);
    if (url.origin !== 'http://127.0.0.1:8793') continue;
    expect((await request.get(url.pathname)).ok(), url.pathname).toBeTruthy();
    if (url.pathname === '/' && url.hash) {
      await expect(page.locator(`[id="${url.hash.slice(1)}"]`)).toHaveCount(1);
    }
  }
  for (const id of ['features', 'how', 'proof', 'eviction', 'write', 'download', 'guides', 'compare']) {
    await expect(page.locator(`[id="${id}"]`)).toHaveCount(1);
  }
  const data = JSON.parse(await page.locator('script[type="application/ld+json"]').textContent());
  expect(data['@graph'].find(item => item['@type'] === 'SoftwareApplication').downloadUrl).toBe(installer);
});

test('video waits for a user gesture, plays, and pauses out of view', async ({ page }) => {
  await page.goto('/');
  const video = page.locator('video');
  await expect(video).toHaveAttribute('preload', 'metadata');
  await expect(video).not.toHaveAttribute('autoplay');
  await expect(video).toHaveJSProperty('paused', true);
  await page.getByRole('link', { name: 'Watch the 30-second demo' }).click();
  await video.focus();
  await page.keyboard.press('Space');
  await expect(video).toHaveJSProperty('paused', false);
  await page.getByRole('heading', { name: 'Leave with more than a recording.' }).scrollIntoViewIfNeeded();
  await expect(video).toHaveJSProperty('paused', true);
  await expect(page.getByText('Read the demo walkthrough', { exact: true })).toBeVisible();
});

test('no JavaScript keeps mobile navigation, product evidence, and downloads available', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false, viewport: viewports[0] });
  const page = await context.newPage();
  await page.goto('http://127.0.0.1:8793/');
  await expect(page.getByRole('navigation', { name: 'Primary', exact: true })).toBeVisible();
  await expect(page.locator('.nav-toggle')).toBeHidden();
  await expect(page.locator('.intro__result figcaption')).toBeVisible();
  await expect(page.getByRole('link', { name: 'Download', exact: true })).toHaveAttribute('href', installer);
  await noOverflow(page);
  await page.goto('http://127.0.0.1:8793/lokalbot-vs-granola');
  for (const item of await page.locator('.reveal').all()) await expect(item).toHaveCSS('opacity', '1');
  await context.close();
});

test('reduced motion and 200% equivalent reflow remain usable', async ({ page }, info) => {
  await page.emulateMedia({ reducedMotion: 'reduce' });
  // Browser zoom to 200% halves the CSS viewport. Check that reflow at 640 × 360;
  // this is a layout equivalent, not a claim of physical-device or browser zoom testing.
  await page.setViewportSize({ width: 640, height: 360 });
  await page.goto('/');
  await noOverflow(page);
  await expect(page.locator('html')).toHaveCSS('scroll-behavior', 'auto');
  await page.getByRole('button', { name: 'Menu', exact: true }).click();
  await expect(page.getByRole('navigation', { name: 'Primary', exact: true })).toBeVisible();
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
      await page.screenshot({ path: info.outputPath(`${route}-${viewport.width}.png`), fullPage: true });
    }
    if (route === 'system-requirements') {
      for (const id of ['first-meeting', 'capture-defaults']) await expect(page.locator(`[id="${id}"]`)).toHaveCount(1);
      await expect(page.locator('article').first()).toContainText('v0.7.2');
    }
  });
}
