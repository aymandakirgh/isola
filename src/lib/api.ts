// Client for the licence server (api/license.ts). `vite preview` has no /api: minting falls back to
// the shared demo key, and recovery says the server couldn't be reached.
import { wait } from "./frame";

/** The server's rule: a plain address, nothing a mail API could read as a name or a second address. */
const ATOM = "[a-z0-9!#$%&'*+/=?^_`{|}~-]+";
const LABEL = "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?";
const EMAIL = new RegExp(
  `^${ATOM}(?:\\.${ATOM})*@${LABEL}(?:\\.${LABEL})+$`,
  "i",
);
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

/** POST /api/license/demo — a new licence key from the no-charge demo checkout, which asks for no
 *  e-mail address, so none is bound to it. */
export async function mintDemoLicense() {
  try {
    return (await post<{ key: string }>("demo", {})).key;
  } catch {
    return DEMO_KEY;
  }
}

/** POST /api/license/recover — the server answers the same for every address; `mail` only says
 *  whether license e-mails are switched on at all. {ok: false} for a malformed address; throws when
 *  the server can't be reached. The 900 ms floor keeps the loading state from flashing. */
export async function requestLicenseEmail(email: string) {
  const address = email.trim();
  const ok = address.length <= 254 && EMAIL.test(address);
  const [reply] = await Promise.all([
    ok &&
      post<{ mail?: boolean }>("recover", { email: address }).catch(
        (error: Error) => error,
      ),
    wait(900),
  ]);
  if (reply instanceof Error) throw reply;
  return { ok, mail: reply ? reply.mail === true : false };
}
