const path = require("node:path");
const { pathToFileURL } = require("node:url");

const playwrightRoot = process.env.PILOZ_PLAYWRIGHT_ROOT;
if (!playwrightRoot) {
  throw new Error("PILOZ_PLAYWRIGHT_ROOT doit pointer vers playwright-core.");
}

const { chromium } = require(playwrightRoot);
const executablePath =
  process.env.PILOZ_CHROME_PATH ||
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const files = process.argv.slice(2);

if (!files.length) {
  throw new Error("Indiquez au moins un fichier HTML de test.");
}

(async () => {
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ["--allow-file-access-from-files"],
  });
  let failed = false;
  try {
    for (const file of files) {
      const page = await browser.newPage();
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page.goto(pathToFileURL(path.resolve(file)).href, {
        waitUntil: "load",
        timeout: 30_000,
      });
      await page.waitForFunction(
        () => {
          const result = document.querySelector("#result, #results");
          return (
            result &&
            !/RUNNING|Vérification|Vérification…/.test(result.textContent || "")
          );
        },
        { timeout: 35_000 },
      );
      const result = await page
        .locator("#result, #results")
        .first()
        .evaluate((node) => ({
          status: node.dataset.status || "",
          text: (node.textContent || "").trim(),
        }));
      const ok =
        result.status !== "failed" &&
        !/^Échec/.test(result.text) &&
        !errors.length;
      failed ||= !ok;
      process.stdout.write(
        `${ok ? "PASS" : "FAIL"} ${path.basename(file)} — ${result.text}${
          errors.length ? ` — ${errors.join(" | ")}` : ""
        }\n`,
      );
      await page.close();
    }
  } finally {
    await browser.close();
  }
  if (failed) process.exitCode = 1;
})().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
