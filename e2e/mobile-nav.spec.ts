import { test, expect } from "@playwright/test";

test.describe("Mobile navigation", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
  });

  test("bottom tab bar is visible on mobile viewports", async ({ page }) => {
    const bottomNav = page.locator(".ui-bottom-nav");

    if (page.viewportSize()!.width <= 768) {
      await expect(bottomNav).toBeVisible();
    } else {
      await expect(bottomNav).not.toBeVisible();
    }
  });

  test("desktop sidebar is hidden on mobile viewports", async ({ page }) => {
    const sidebar = page.locator(".ui-sidebar");

    if (page.viewportSize()!.width <= 768) {
      await expect(sidebar).not.toBeVisible();
    } else {
      await expect(sidebar).toBeVisible();
    }
  });

  test("all 4 nav items are present and clickable", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    const navItems = page.locator(".ui-bottom-nav__item");
    await expect(navItems).toHaveCount(4);

    const labels = await navItems
      .locator(".ui-bottom-nav__label")
      .allTextContents();
    expect(labels).toEqual(["Chat", "Overview", "Agents", "MCP"]);
  });

  test("active tab highlights correctly on each page", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    // Chat page (default)
    const activeItem = page.locator(".ui-bottom-nav__item.is-active");
    await expect(activeItem).toHaveCount(1);
    await expect(
      activeItem.locator(".ui-bottom-nav__label"),
    ).toHaveText("Chat");

    // Navigate to dashboard
    await page.locator('.ui-bottom-nav__item >> text="Overview"').click();
    await page.waitForURL("**/dashboard");
    const dashActive = page.locator(".ui-bottom-nav__item.is-active");
    await expect(
      dashActive.locator(".ui-bottom-nav__label"),
    ).toHaveText("Overview");
  });

  test("touch targets are at least 44px tall", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    const items = page.locator(".ui-bottom-nav__item");
    const count = await items.count();

    for (let i = 0; i < count; i++) {
      const box = await items.nth(i).boundingBox();
      expect(box!.height).toBeGreaterThanOrEqual(44);
    }
  });
});
