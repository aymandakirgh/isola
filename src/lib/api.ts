// Client for the licence server (api/license.ts). `vite preview` has no /api, so every call here
// falls back instead of failing.
import { wait } from "./frame";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
/** Shared key the Mac app always accepts, for when the licence server can't be reached. */
const DEMO_KEY = "ISOLA-DEMO-7Q4K-2M9X";

async function post<T>(action: string, body: object): Promise<T> {
  const response = await fetch(`/api/license/${action}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok)
    throw new Error(`/api/license/${action}: ${response.status}`);
  return response.json();
}

/** POST /api/license/demo — a new licence from the no-charge demo checkout. */
export async function mintDemoLicense(email: string) {
  try {
    return await post<{ key: string; email: string | null }>(
      "demo",
      email ? { email } : {},
    );
  } catch {
    return { key: DEMO_KEY, email: email || null };
  }
}

/** POST /api/license/recover — the server answers the same for every address, so any well-formed
 *  one "succeeds"; the 900 ms floor keeps the loading state from flashing. */
export async function requestLicenseEmail(email: string) {
  const ok = EMAIL.test(email.trim());
  await Promise.all([
    wait(900),
    ok && post("recover", { email: email.trim() }).catch(() => {}),
  ]);
  return { ok };
}
