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
 * Set files on the LiveView upload input and trigger the LV upload hook.
 * Playwright's setInputFiles() alone doesn't fire LiveView's internal
 * file tracking — we need to re-dispatch a change event so the
 * Phoenix.LiveFileUpload hook calls trackFiles().
 */
async function triggerLiveViewUpload(
  page: Page,
  files: string | string[],
): Promise<void> {
  const fileInput = page.locator("input[data-phx-upload-ref]");
  await fileInput.setInputFiles(files);
  await page.evaluate(() => {
    const input = document.querySelector(
      'input[data-phx-upload-ref]',
    ) as HTMLInputElement;
    if (input) {
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
  });
  // Wait for LiveView to process the upload and render previews
  await page.locator('.ui-upload-previews').waitFor({ state: 'visible', timeout: 5000 });
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
      await page.locator('.ui-chat-composer').waitFor({ state: 'visible', timeout: 5000 });
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
});
