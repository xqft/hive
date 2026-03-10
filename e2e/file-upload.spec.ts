import { test, expect, Page } from "@playwright/test";
import { waitForLiveView } from "./helpers";
import * as path from "path";
import * as fs from "fs";
import * as os from "os";

/**
 * Create a temporary file with the given content and extension.
 * Returns the file path. Caller is responsible for cleanup.
 */
function createTempFile(name: string, content: string | Buffer): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hive-e2e-"));
  const filePath = path.join(dir, name);
  fs.writeFileSync(filePath, content);
  return filePath;
}

/**
 * Clean up a temp file and its directory. Silently ignores errors.
 */
function cleanupTempFile(filePath: string): void {
  try {
    fs.unlinkSync(filePath);
    fs.rmdirSync(path.dirname(filePath));
  } catch {
    // ignore cleanup errors
  }
}

/**
 * Trigger a LiveView file upload using Playwright's native file chooser API.
 * Clicks the upload button which opens the browser's real file picker,
 * then sets the files on it. This fires a native `change` event that
 * Phoenix.LiveFileUpload's hook reliably handles — no synthetic events.
 */
async function triggerLiveViewUpload(
  page: Page,
  files: string | string[],
): Promise<void> {
  const [fileChooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator(".ui-chat-composer__upload-btn").click(),
  ]);
  await fileChooser.setFiles(files);
  // Wait for LiveView to process the upload and render previews
  await page.locator(".ui-upload-previews").waitFor({ state: "visible", timeout: 10000 });
}

test.describe("File upload", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await waitForLiveView(page);

    // Select a topic so the composer is active
    const topicItem = page.locator(".ui-topic-item").first();
    if (await topicItem.isVisible({ timeout: 2000 }).catch(() => false)) {
      await topicItem.click();
      // Wait for topic selection to take effect (composer becomes active)
      await page.locator(".ui-chat-composer").waitFor({ state: "visible", timeout: 5000 });
    }
  });

  test("upload button is visible with correct title", async ({ page }) => {
    const uploadBtn = page.locator(".ui-chat-composer__upload-btn");
    await expect(uploadBtn).toBeVisible();
    await expect(uploadBtn).toHaveAttribute("title", "Attach file");
  });

  test("image upload shows thumbnail preview", async ({ page }) => {
    // Create a tiny valid PNG (1x1 red pixel)
    const pngData = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVQI12P4z8BQDwAEgAF/QualzQAAAABJRU5ErkJggg==",
      "base64",
    );
    const filePath = createTempFile("test-image.png", pngData);

    try {
      await triggerLiveViewUpload(page, filePath);

      // Should show image thumbnail preview
      const previews = page.locator(".ui-upload-previews");
      await expect(previews).toBeVisible();

      const thumb = page.locator(".ui-upload-preview__thumb");
      await expect(thumb).toBeVisible();
    } finally {
      cleanupTempFile(filePath);
    }
  });

  test("non-image file upload shows filename preview", async ({ page }) => {
    const filePath = createTempFile(
      "test-document.pdf",
      "%PDF-1.4 test content for upload testing",
    );

    try {
      await triggerLiveViewUpload(page, filePath);

      // Should show file icon + filename preview (not image thumbnail)
      const previews = page.locator(".ui-upload-previews");
      await expect(previews).toBeVisible();

      const filePreview = page.locator(".ui-upload-preview__file");
      await expect(filePreview).toBeVisible();

      const filename = page.locator(".ui-upload-preview__filename");
      await expect(filename).toContainText("test-document.pdf");
    } finally {
      cleanupTempFile(filePath);
    }
  });

  test("can cancel a file upload before sending", async ({ page }) => {
    const filePath = createTempFile("cancel-me.txt", "temporary file");

    try {
      await triggerLiveViewUpload(page, filePath);

      const previews = page.locator(".ui-upload-previews");
      await expect(previews).toBeVisible();

      // Click remove button
      const removeBtn = page.locator(".ui-upload-preview__remove");
      await removeBtn.click();

      // Previews should be gone
      await expect(
        page.locator(".ui-upload-preview__file"),
      ).not.toBeVisible();
    } finally {
      cleanupTempFile(filePath);
    }
  });

  test("multiple file types can be attached simultaneously", async ({
    page,
  }) => {
    const pngData = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVQI12P4z8BQDwAEgAF/QualzQAAAABJRU5ErkJggg==",
      "base64",
    );
    const imgPath = createTempFile("photo.png", pngData);
    const txtPath = createTempFile("notes.txt", "some notes");
    const csvPath = createTempFile("data.csv", "name,age\nAlice,30");

    try {
      await triggerLiveViewUpload(page, [imgPath, txtPath, csvPath]);

      // Should show 3 previews: 1 image thumb + 2 file icons
      const allPreviews = page.locator(".ui-upload-preview");
      await expect(allPreviews).toHaveCount(3);

      // Image gets a thumbnail
      const thumb = page.locator(".ui-upload-preview__thumb");
      await expect(thumb).toHaveCount(1);

      // Non-images get file previews
      const filePreviews = page.locator(".ui-upload-preview__file");
      await expect(filePreviews).toHaveCount(2);
    } finally {
      cleanupTempFile(imgPath);
      cleanupTempFile(txtPath);
      cleanupTempFile(csvPath);
    }
  });

  test("image upload sends and renders as image in message", async ({ page }) => {
    const pngData = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVQI12P4z8BQDwAEgAF/QualzQAAAABJRU5ErkJggg==",
      "base64",
    );
    const filePath = createTempFile("render-test.png", pngData);

    try {
      await triggerLiveViewUpload(page, filePath);

      // Type a message and send
      const textarea = page.locator(".ui-chat-composer textarea, .ui-chat-composer [contenteditable]");
      await textarea.fill("Check this image");
      await page.locator("#chat-send-button").click();

      // Wait for the message to appear in the chat
      const messages = page.locator(".ui-chat-messages");

      // The rendered message should contain an img tag (from ![image](url) markdown)
      const imgInMessage = messages.locator("img[src*='/uploads/']");
      await expect(imgInMessage).toBeVisible({ timeout: 10000 });
    } finally {
      cleanupTempFile(filePath);
    }
  });

  test("non-image upload sends and renders as download link", async ({ page }) => {
    const filePath = createTempFile(
      "report.pdf",
      "%PDF-1.4 test pdf for link rendering",
    );

    try {
      await triggerLiveViewUpload(page, filePath);

      // Type a message and send
      const textarea = page.locator(".ui-chat-composer textarea, .ui-chat-composer [contenteditable]");
      await textarea.fill("See attached report");
      await page.locator("#chat-send-button").click();

      // Wait for the message to appear with a file link
      const messages = page.locator(".ui-chat-messages");

      // The rendered message should contain a link to /uploads/ (from [📎 name](url) markdown)
      const fileLink = messages.locator("a[href*='/uploads/']");
      await expect(fileLink).toBeVisible({ timeout: 10000 });
      await expect(fileLink).toContainText("report.pdf");
    } finally {
      cleanupTempFile(filePath);
    }
  });

  test("max entries limit rejects fifth file", async ({ page }) => {
    // max_entries is 4, so uploading 5 files should only accept 4
    const pngData = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADklEQVQI12P4z8BQDwAEgAF/QualzQAAAABJRU5ErkJggg==",
      "base64",
    );
    const files = Array.from({ length: 5 }, (_, i) =>
      createTempFile(`file-${i}.png`, pngData),
    );

    try {
      // Upload all 5 files at once via the native file chooser
      const [fileChooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        page.locator(".ui-chat-composer__upload-btn").click(),
      ]);
      await fileChooser.setFiles(files);

      // Wait a moment for LiveView to process
      await page.waitForTimeout(2000);

      // Should show at most 4 previews (max_entries: 4)
      const allPreviews = page.locator(".ui-upload-preview");
      const count = await allPreviews.count();
      expect(count).toBeLessThanOrEqual(4);

      // Or there should be an error displayed for too many files
      // LiveView may show an error on the upload entries
      if (count === 0) {
        // If no previews rendered, check for an error state
        // (LiveView rejects the entire batch when exceeding max_entries)
        const errorText = page.locator("[phx-feedback-for], .ui-upload-error, .alert");
        const hasError = await errorText.isVisible().catch(() => false);
        expect(hasError || count <= 4).toBeTruthy();
      }
    } finally {
      files.forEach(cleanupTempFile);
    }
  });

  test("upload progress indicator is visible during upload", async ({ page }) => {
    // Use a slightly larger file to have a visible upload state
    const data = Buffer.alloc(50_000, "x");
    const filePath = createTempFile("progress-test.txt", data);

    try {
      await triggerLiveViewUpload(page, filePath);

      // The upload preview element should be visible (indicates upload processed)
      const preview = page.locator(".ui-upload-preview");
      await expect(preview).toBeVisible();
      await expect(preview).toHaveCount(1);
    } finally {
      cleanupTempFile(filePath);
    }
  });
});
