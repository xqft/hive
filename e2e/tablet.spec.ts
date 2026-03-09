import { test, expect } from "@playwright/test";

test.describe("Tablet layout", () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 850, height: 1024 });
    await page.goto("/");
  });

  test("icon-only sidebar rail visible", async ({ page }) => {
    const sidebar = page.locator(".ui-sidebar");
    await expect(sidebar).toBeVisible();

    const box = await sidebar.boundingBox();
    // Should be approximately 4rem (64px) wide
    expect(box!.width).toBeLessThan(80);
    expect(box!.width).toBeGreaterThan(40);
  });

  test("nav items show only icons, text hidden", async ({ page }) => {
    const navLinks = page.locator(".ui-nav-link");
    await expect(navLinks).not.toHaveCount(0);

    // Icons should be visible
    const icons = page.locator(".ui-nav-link .hero-chat-bubble-left-right, .ui-nav-link .hero-squares-2x2, .ui-nav-link .hero-users, .ui-nav-link .hero-command-line");
    const iconCount = await icons.count();
    expect(iconCount).toBeGreaterThan(0);

    // Text labels should be hidden
    const labels = page.locator(".ui-nav-link span");
    const count = await labels.count();
    for (let i = 0; i < count; i++) {
      await expect(labels.nth(i)).not.toBeVisible();
    }
  });

  test("content area fills remaining space", async ({ page }) => {
    const workspace = page.locator(".ui-workspace");
    await expect(workspace).toBeVisible();

    const box = await workspace.boundingBox();
    // Content should take most of the width (850 - ~64px sidebar - gaps)
    expect(box!.width).toBeGreaterThan(700);
  });

  test("sidebar extras are hidden on tablet", async ({ page }) => {
    const extra = page.locator(".ui-sidebar__extra");
    if ((await extra.count()) > 0) {
      await expect(extra).not.toBeVisible();
    }

    const footer = page.locator(".ui-sidebar__footer");
    if ((await footer.count()) > 0) {
      await expect(footer).not.toBeVisible();
    }
  });
});
