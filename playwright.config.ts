import { defineConfig, devices } from '@playwright/test';

// Standard GH — vedi KB 09-Skills/Playwright-E2E-Testing-skill.md
// BASE_URL: override per puntare a preview/prod (default: dev server locale)
const baseURL = process.env.BASE_URL ?? 'http://localhost:3000';

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    // browserName forzato: iPhone 14 di default vorrebbe WebKit, ma lo standard
    // GH installa solo Chromium — mobile = emulazione viewport/UA su Chromium.
    { name: 'mobile', use: { ...devices['iPhone 14'], browserName: 'chromium' } },
  ],
});
