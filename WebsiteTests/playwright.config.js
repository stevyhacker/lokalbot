const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  testMatch: '*.spec.js',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 30_000,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://127.0.0.1:8793',
    viewport: { width: 1280, height: 720 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  },
  webServer: [
    {
      command: 'python3 ../Scripts/serve-web.py 8793',
      url: 'http://127.0.0.1:8793',
      reuseExistingServer: false
    },
    ...(process.env.WEBSITE_BASELINE ? [{
      command: 'python3 ../Scripts/serve-web.py 8794 --directory "$WEBSITE_BASELINE"',
      url: 'http://127.0.0.1:8794',
      reuseExistingServer: false
    }] : [])
  ]
});
