// Stand-ins for the licensing backend; swap for real fetch calls when one exists.
import { DOWNLOAD_URL } from "../config";
import { wait } from "./frame";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** POST /license/notify — a licence "exists" for any well-formed address. */
export async function requestLicenseEmail(email: string) {
  await wait(900);
  return { ok: EMAIL.test(email.trim()) };
}

/** GET /checkout/:id — only the demo checkout resolves. */
export async function getCheckout(id: string) {
  await wait(700);
  return id === "demo"
    ? { email: "you@example.com", license_key: "ISOLA-DEMO-7Q4K-2M9X", download_url: DOWNLOAD_URL }
    : null;
}
