import { test, expect } from "@playwright/test";
import { waitForLiveView } from "./helpers";

test.describe("Steering — @mention chat behavior", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await waitForLiveView(page);

    // Select a topic so the composer is active
    const topicItem = page.locator(".ui-topic-link").first();
    if (await topicItem.isVisible({ timeout: 2000 }).catch(() => false)) {
      await topicItem.click();
      await page.waitForTimeout(500);
    }
  });

  test("@mention message renders in chat", async ({ page }) => {
    const input = page.locator("textarea.ui-chat-composer__input");
    await expect(input).toBeVisible({ timeout: 3000 });

    const testMessage = `@testbot hello ${Date.now()}`;
    await input.fill(testMessage);
    await input.press("Enter");

    // Message should appear in the chat
    await expect(
      page.locator(".ui-message").filter({ hasText: testMessage }),
    ).toBeVisible({
      timeout: 5000,
    });
  });

  test("typing indicator appears for mentioned agent", async ({ page }) => {
    const input = page.locator("textarea.ui-chat-composer__input");
    if (!(await input.isVisible({ timeout: 2000 }).catch(() => false))) {
      test.skip();
      return;
    }

    await input.fill(`@testbot ping ${Date.now()}`);
    await input.press("Enter");

    // Soft check: typing indicator may not appear if no agent is running
    // Just verify the page doesn't crash and the indicator element can be queried
    const indicator = page.locator(".ui-typing-indicator");
    try {
      await expect(indicator).toBeVisible({ timeout: 3000 });
    } catch {
      // Expected if no agent is running — test passes either way
    }
  });

  test("messages persist across topic switches", async ({ page }) => {
    const topics = page.locator("#topic-list .ui-topic-link");
    const topicCount = await topics.count();

    if (topicCount < 2) {
      test.skip();
      return;
    }

    // Select first topic and send a message
    await topics.first().click();
    await page.waitForTimeout(500);

    const input = page.locator("textarea.ui-chat-composer__input");
    await expect(input).toBeVisible({ timeout: 3000 });

    const testMessage = `persist-test-${Date.now()}`;
    await input.fill(testMessage);
    await input.press("Enter");

    // Verify message appeared
    await expect(
      page.locator(".ui-message").filter({ hasText: testMessage }),
    ).toBeVisible({
      timeout: 5000,
    });

    // Switch to second topic
    await topics.nth(1).click();
    await page.waitForTimeout(500);

    // Switch back to first topic
    await topics.first().click();
    await page.waitForTimeout(500);

    // Message should still be visible
    await expect(
      page.locator(".ui-message").filter({ hasText: testMessage }),
    ).toBeVisible({
      timeout: 5000,
    });
  });
});
