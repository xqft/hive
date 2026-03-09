import type { Page } from "@playwright/test";

/**
 * Wait for Phoenix LiveView to be fully connected.
 * Checks that the LiveSocket has connected and the page is interactive.
 */
export async function waitForLiveView(page: Page) {
  // Wait for the phx-session element to exist (static render done)
  await page.waitForSelector("[data-phx-session]", { timeout: 10000 });

  // Wait for LiveView to connect by checking the liveSocket is connected
  await page.waitForFunction(
    () => {
      const w = window as any;
      return w.liveSocket && w.liveSocket.isConnected();
    },
    { timeout: 10000 },
  );
}
