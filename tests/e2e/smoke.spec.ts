import { expect, test, type Page } from "@playwright/test";

// Smoke test standard GH: every route renders without console errors, on desktop and mobile.
// A failed /api request doesn't count: `vite preview` serves no /api and the pages fall back.
function collectErrors(page: Page) {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on(
    "console",
    (msg) =>
      msg.type() === "error" &&
      !msg.location().url.includes("/api/") &&
      errors.push(msg.text()),
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

test("the download is the real DMG the card describes", async ({
  page,
  request,
}) => {
  const dmg = await request.head("/downloads/Isola.dmg");
  expect(dmg.status()).toBe(200);
  const megabytes = Math.floor(Number(dmg.headers()["content-length"]) / 1e6);
  await page.goto("/download");
  await expect(page.getByText(`DMG, ${megabytes}MB`)).toBeVisible();
  // The Mac app's update feed announces the same version the card offers.
  const feed = await (await request.get("/releases.json")).json();
  await expect(page.getByText(`v${feed.version}`)).toBeVisible();
});

test("the purchase page shows a license key (the shared demo key without /api)", async ({
  page,
}) => {
  await page.goto("/purchased/demo");
  await expect(
    page.getByText(/^ISOLA-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/),
  ).toBeVisible();
});

test("the download link never carries the license key", async ({ page }) => {
  await page.goto("/purchased/demo?code=ISOLA-W7UD-A389-NXLG");
  await expect(page.getByText("ISOLA-W7UD-A389-NXLG")).toBeVisible();
  await expect(page.locator("a[download]")).toHaveAttribute(
    "href",
    "/downloads/Isola.dmg",
  );
});

test("the clock's font comes from this site, not Google Fonts", async ({
  page,
  isMobile,
}) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await page.goto("/");
  if (!isMobile) {
    // The clock shows from the md breakpoint up.
    await expect(page.locator("time.font-numeric")).toBeVisible();
    await page.evaluate(() => document.fonts.ready);
    expect(
      await page.evaluate(() =>
        document.fonts.check("800 96px Nunito", "0123456789:"),
      ),
    ).toBe(true);
    expect(requests.some((u) => u.endsWith("/fonts/nunito-digits.woff2"))).toBe(
      true,
    );
  }
  expect(
    requests.filter((u) => /fonts\.(googleapis|gstatic)\.com/.test(u)),
  ).toEqual([]);
});

test("the privacy policy says what is kept", async ({ page }) => {
  await page.goto("/privacy");
  await expect(page.getByText(/hashed hardware ID/)).toBeVisible();
  await expect(page.getByText(/no data/i)).toHaveCount(0);
  await expect(page.locator('meta[name="description"]')).toHaveAttribute(
    "content",
    "What Isola keeps for your license, and why",
  );
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

test("license recovery shakes on a bad address, and on a good one when nothing could be sent", async ({
  page,
}) => {
  await page.goto("/recover");
  const input = page.locator("input");
  await input.fill("nope");
  await input.press("Enter");
  await expect(page.locator(".animate-shake")).toBeAttached();
  await expect(input).toHaveValue("");
  // `vite preview` serves no /api: the request fails, and the address stays for another try.
  await input.fill("you@example.com");
  await expect(page.locator(".animate-shake")).toHaveCount(0);
  await input.press("Enter");
  await expect(page.locator(".animate-shake")).toBeAttached();
  await expect(input).toHaveValue("you@example.com");
});

for (const [mail, copy] of [
  [true, /^If that address has a license, it’s on its way\.$/],
  [false, /^License e-mails aren’t set up on this demo yet\.$/],
] as const)
  test(`license recovery says what happens next when mail is ${mail ? "on" : "off"}`, async ({
    page,
  }) => {
    const sent: unknown[] = [];
    await page.route("**/api/license/recover", (route) => {
      sent.push(route.request().postDataJSON());
      return route.fulfill({ status: 202, json: { mail } });
    });
    await page.goto("/recover");
    const input = page.locator("input");
    await input.fill(" You+Shop@Example.com ");
    await input.press("Enter");
    await expect(page.getByText(copy)).toBeVisible();
    expect(sent).toEqual([{ email: "You+Shop@Example.com" }]);
  });
