import { expect, test, type Page } from "@playwright/test";

// Smoke test standard GH: every route renders without console errors, on desktop and mobile.
function collectErrors(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on(
    "console",
    (msg) => msg.type() === "error" && errors.push(msg.text()),
  );
  return errors;
}

const ROUTES: [string, RegExp][] = [
  ["/", /Dynamic Island/],
  ["/faqs", /FAQs/],
  ["/changelog", /Changelog/],
  ["/download", /Download/],
  ["/privacy", /Privacy policy/],
  ["/recover", /Recover/],
  ["/purchased/demo", /Thanks for/],
];

for (const [path, heading] of ROUTES) {
  test(`${path} renders without console errors`, async ({ page }) => {
    const errors = collectErrors(page);
    const response = await page.goto(path);
    expect(response?.status()).toBeLessThan(400);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(heading);
    expect(errors, errors.join(" | ")).toEqual([]);
  });
}

test("the download is the real DMG the card describes", async ({ page, request }) => {
  const dmg = await request.head("/downloads/Isola.dmg");
  expect(dmg.status()).toBe(200);
  const megabytes = Math.floor(Number(dmg.headers()["content-length"]) / 1e6);
  await page.goto("/download");
  await expect(page.getByText(`DMG, ${megabytes}MB`)).toBeVisible();
});

test("unknown paths fall back to home", async ({ page }) => {
  await page.goto("/does-not-exist");
  await expect(page).toHaveURL(/\/$/);
});

test("lock screen unlocks and the earbuds notification follows", async ({
  page,
  isMobile,
}) => {
  const errors = collectErrors(page);
  await page.goto("/");
  await page.getByText("Press to unlock").click();
  await expect(page.getByText("Press to unlock")).toHaveCount(0);
  if (!isMobile)
    await expect(
      page.getByRole("link", { name: "Privacy policy" }),
    ).toBeAttached();
  await expect(
    page.locator('video source[src="/videos/earbuds.mp4"]'),
  ).toBeAttached({ timeout: 5_000 });
  expect(errors, errors.join(" | ")).toEqual([]);
});

test("navigating to FAQs swaps to the dark theme", async ({
  page,
  isMobile,
}) => {
  await page.goto("/");
  await page.mouse.move(10, 10); // header buttons wake up on pointer movement
  await page.locator('header a[href="/faqs"]').click();
  await expect(page).toHaveURL(/\/faqs$/);
  await expect(page.locator("html")).toHaveClass(/dark/);
  await expect(page).toHaveTitle(/FAQs/);
  if (!isMobile)
    await expect(page.locator('header a[href="/faqs"]')).toHaveCount(0);
});

test("license recovery shakes on a bad address and succeeds on a good one", async ({
  page,
}) => {
  await page.goto("/recover");
  const input = page.locator("input");
  await input.fill("nope");
  await input.press("Enter");
  await expect(page.locator(".animate-shake")).toBeAttached();
  await input.fill("you@example.com");
  await input.press("Enter");
  await expect(page.getByText("License found!")).toBeVisible();
});
