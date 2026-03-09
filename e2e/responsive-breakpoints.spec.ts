import { test, expect } from "@playwright/test";

test.describe("Responsive breakpoints", () => {
  test("at 769-920px: sidebar shows icon-only rail", async ({ page }) => {
    await page.setViewportSize({ width: 850, height: 900 });
    await page.goto("/");

    const sidebar = page.locator(".ui-sidebar");
    await expect(sidebar).toBeVisible();

    const box = await sidebar.boundingBox();
    // Icon rail should be around 4rem (64px) wide
    expect(box!.width).toBeLessThan(80);

    // Text labels should be hidden
    const navText = page.locator(".ui-nav-link span");
    const count = await navText.count();
    for (let i = 0; i < count; i++) {
      await expect(navText.nth(i)).not.toBeVisible();
    }

    // Bottom nav should NOT be visible at tablet size
    const bottomNav = page.locator(".ui-bottom-nav");
    await expect(bottomNav).not.toBeVisible();
  });

  test("at 768px: sidebar hidden, bottom nav appears", async ({ page }) => {
    await page.setViewportSize({ width: 768, height: 1024 });
    await page.goto("/");

    const sidebar = page.locator(".ui-sidebar");
    await expect(sidebar).not.toBeVisible();

    const bottomNav = page.locator(".ui-bottom-nav");
    await expect(bottomNav).toBeVisible();
  });

  test("at 1024px+: full sidebar visible, no bottom nav", async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 768 });
    await page.goto("/");

    const sidebar = page.locator(".ui-sidebar");
    await expect(sidebar).toBeVisible();

    const box = await sidebar.boundingBox();
    // Full sidebar should be wider than icon rail
    expect(box!.width).toBeGreaterThan(200);

    const bottomNav = page.locator(".ui-bottom-nav");
    await expect(bottomNav).not.toBeVisible();
  });

  test("no horizontal scrollbar at any tested width", async ({ page }) => {
    const widths = [320, 375, 768, 1024, 1280];

    for (const width of widths) {
      await page.setViewportSize({ width, height: 800 });
      await page.goto("/");
      await page.waitForLoadState("networkidle");

      const hasOverflow = await page.evaluate(() => {
        return document.documentElement.scrollWidth > window.innerWidth;
      });

      expect(hasOverflow, `Horizontal overflow at ${width}px`).toBe(false);
    }
  });
});
