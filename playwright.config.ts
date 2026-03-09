import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: "html",
  use: {
    baseURL: "http://localhost:4002",
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "mobile-chrome",
      use: {
        ...devices["Pixel 5"],
      },
    },
    {
      name: "mobile-safari",
      use: {
        ...devices["iPhone 12"],
      },
    },
    {
      name: "tablet",
      use: {
        viewport: { width: 768, height: 1024 },
        userAgent:
          "Mozilla/5.0 (iPad; CPU OS 15_0 like Mac OS X) AppleWebKit/605.1.15",
      },
    },
    {
      name: "desktop",
      use: {
        viewport: { width: 1280, height: 800 },
        ...devices["Desktop Chrome"],
      },
    },
  ],
  webServer: {
    command: "MIX_ENV=test mix phx.server",
    url: "http://localhost:4002",
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
  },
});
