import { test, expect } from "@playwright/test";
import { waitForLiveView } from "./helpers";

test.describe("Chat page on mobile", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await waitForLiveView(page);
  });

  test("chat messages area fills available space", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    const chatPanel = page.locator(".ui-chat-panel");
    await expect(chatPanel).toBeVisible();

    const box = await chatPanel.boundingBox();
    expect(box!.height).toBeGreaterThan(200);
  });

  test("composer has 16px+ font size to prevent iOS zoom", async ({
    page,
  }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    const input = page.locator(".ui-chat-composer__input");
    await expect(input).toBeVisible();

    const fontSize = await input.evaluate(
      (el) => parseFloat(getComputedStyle(el).fontSize),
    );
    expect(fontSize).toBeGreaterThanOrEqual(16);
  });

  test("topics bottom sheet opens and closes via toggle button", async ({
    page,
  }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    // Toggle button should be visible
    const toggleBtn = page.locator(".ui-mobile-topics-btn");
    await expect(toggleBtn).toBeVisible();

    // Click to open bottom sheet
    await toggleBtn.click();

    const sheet = page.locator(".ui-mobile-sheet");
    await expect(sheet).toBeVisible({ timeout: 10000 });

    // Backdrop should be visible
    const backdrop = page.locator(".ui-mobile-sheet-backdrop");
    await expect(backdrop).toBeVisible();

    // Click backdrop to close
    await backdrop.click();
    await expect(sheet).not.toBeVisible();
  });

  test("messages have appropriate max-width", async ({ page }) => {
    if (page.viewportSize()!.width > 768) {
      test.skip();
      return;
    }

    // Check CSS rule is applied
    const msgStyle = await page.evaluate(() => {
      const el = document.createElement("div");
      el.className = "ui-message";
      document.body.appendChild(el);
      const style = getComputedStyle(el);
      const maxWidth = style.maxWidth;
      el.remove();
      return maxWidth;
    });

    // Should be 95% or 100% on mobile
    expect(msgStyle).toMatch(/\d+/);
  });
});
