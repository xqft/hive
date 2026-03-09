import { test, expect } from "@playwright/test";

test.describe("Mobile pages", () => {
  test("dashboard stat cards stack vertically", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    await page.goto("/dashboard");

    const cardGrid = page.locator(".ui-card-grid");
    if ((await cardGrid.count()) === 0) return;

    const gridStyle = await cardGrid.evaluate(
      (el) => getComputedStyle(el).gridTemplateColumns,
    );
    // Should be single column on mobile
    expect(gridStyle).not.toContain("repeat");
  });

  test("agents page: list visible by default, selecting shows editor with back button", async ({
    page,
  }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    await page.goto("/agents");

    // The "New agent" button should be visible (list view)
    const newAgentBtn = page.locator('button:has-text("New agent")');
    await expect(newAgentBtn).toBeVisible();

    // Click "New agent" to switch to editor view
    await newAgentBtn.click();

    // Back button should appear
    const backBtn = page.locator(".ui-mobile-back-btn");
    await expect(backBtn).toBeVisible();

    // Click back to return to list
    await backBtn.click();
    await expect(newAgentBtn).toBeVisible();
  });

  test("MCP page: same list/editor toggle pattern", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    await page.goto("/mcp");

    const installBtn = page.locator('button:has-text("Install MCP server")');
    await expect(installBtn).toBeVisible();

    await installBtn.click();

    const backBtn = page.locator(".ui-mobile-back-btn");
    await expect(backBtn).toBeVisible();

    await backBtn.click();
    await expect(installBtn).toBeVisible();
  });

  test("no horizontal overflow on mobile", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    for (const path of ["/", "/dashboard", "/agents", "/mcp"]) {
      await page.goto(path);
      await page.waitForLoadState("networkidle");

      const hasOverflow = await page.evaluate(() => {
        return document.documentElement.scrollWidth > window.innerWidth;
      });

      expect(hasOverflow, `Page ${path} has horizontal overflow`).toBe(false);
    }
  });
});
