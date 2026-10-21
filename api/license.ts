// Isola licence server: one Vercel Function (Node.js runtime, Web-standard `fetch` export) for every
// /api/license/<action> route; vercel.json rewrites them here, as Vercel recommends for a non-Next.js
// /api (one shared function routed by path): https://vercel.com/docs/functions/runtimes/node-js
//
//   POST /api/license/demo        {email?}                          → 201 {key, email}
//   POST /api/license/activate    {key, device: {id, name, model}}  → 200 {devices}  (409 past 3 Macs)
//   POST /api/license/devices     {key, deviceId}                   → 200 {devices}  (403 unless deviceId is on the key)
//   POST /api/license/deactivate  {key, deviceId, target}           → 200 {devices}  (403 for a Mac activated before the caller)
//   POST /api/license/recover     {email}                           → 202 {mail}     (the same for every address)
//
// A Mac's id is its credential, so {devices} shows the caller its own id and every other Mac as an
// opaque handle, which is what deactivate's `target` takes. Every POST must be JSON (415 otherwise).
// Errors are {error} with a sentence the Mac app shows as is; a throttle is a 503 with Retry-After,
// never a 429. Payments stay a no-charge demo.
import { createHash, createHmac, randomInt } from "node:crypto";
import { BlobError, BlobPreconditionFailedError, get, put } from "@vercel/blob";
import { waitUntil } from "@vercel/functions";

/** Same alphabet and checksum as the Mac app: mac/Sources/Isola/Modules/Settings/License.swift. */
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/** The website's public demo key: valid everywhere, no device limit, and no stored device list. */
const DEMO_KEY = "ISOLA-DEMO-7Q4K-2M9X";
const DEVICE_LIMIT = 3;
/** An address's index lists at most this many keys. */
const EMAIL_KEYS = 20;
/** A plain addr-spec: dot-atoms around one @, nothing a mail API could read as a display name, a
 *  group or a second address (no quotes, angle brackets, commas, semicolons or spaces). The site
 *  checks the same: src/lib/api.ts. */
const ATOM = "[a-z0-9!#$%&'*+/=?^_`{|}~-]+";
const LABEL = "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?";
const EMAIL = new RegExp(
  `^${ATOM}(?:\\.${ATOM})*@${LABEL}(?:\\.${LABEL})+$`,
  "i",
);
const HOUR = 3_600_000;
/** Keys the HMACs (device handles, e-mail index names) when LICENSE_SECRET isn't set: tests and local
 *  runs only, since it's public and protects nothing. Production refuses to run without the real one. */
const DEV_SECRET = "isola-dev-secret";
const NOT_SET_UP =
  "The license server isn’t set up yet. Please try again later.";
const BUSY = "The license server is busy. Please try again in a moment.";

type Device = { id: string; name: string; model: string; activated: string };
type License = { key: string; created: string; devices: Device[] };
type EmailIndex = { keys: string[] };
type Body = Record<string, unknown>;

class HttpError extends Error {
  status: number;
  headers?: Record<string, string>;
  constructor(
    status: number,
    message: string,
    headers?: Record<string, string>,
  ) {
    super(message);
    this.status = status;
    this.headers = headers;
  }
}

// MARK: Keys: ISOLA-XXXX-XXXX-XXXX, the last character a weighted checksum of the other eleven.

function checksum(chars: string) {
  let sum = 0;
  for (let i = 0; i < chars.length; i++)
    sum += ALPHABET.indexOf(chars[i]) * (i + 7);
  return ALPHABET[sum % ALPHABET.length];
}

export function isValidKey(key: string) {
  if (key === DEMO_KEY) return true;
  const groups =
    /^ISOLA-([A-HJ-NP-Z2-9]{4})-([A-HJ-NP-Z2-9]{4})-([A-HJ-NP-Z2-9]{4})$/.exec(
      key,
    );
  const body = groups ? groups.slice(1).join("") : "";
  return body.length === 12 && checksum(body.slice(0, 11)) === body[11];
}

function mintKey() {
  const body = Array.from(
    { length: 11 },
    () => ALPHABET[randomInt(ALPHABET.length)],
  ).join("");
  const full = body + checksum(body);
  return `ISOLA-${full.slice(0, 4)}-${full.slice(4, 8)}-${full.slice(8)}`;
}

// MARK: Secrets: one HMAC key names the e-mail indexes and hides other Macs' ids.

function secret() {
  const value = process.env.LICENSE_SECRET;
  if (value) return value;
  if (process.env.VERCEL_ENV === "production")
    throw new HttpError(503, NOT_SET_UP);
  return DEV_SECRET;
}

const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const hmac = (value: string) =>
  createHmac("sha256", secret()).update(value).digest();
/** Another Mac as the caller sees it: an id only this server can tie back to that Mac. */
const handle = (key: string, id: string) =>
  hmac(`${key}:${id}`).toString("base64url").slice(0, 22);

// MARK: Storage: one private JSON object per licence, named by a hash of its key, and one per e-mail
// address listing its keys, named by an HMAC of the address (so the store's listing can't be matched
// against known addresses). Licences don't hold the address. Vercel Blob in a private store
// (https://vercel.com/docs/vercel-blob/private-storage) or, with no store configured (local runs,
// tests), this process's memory.
//
// Records written before that change keep their old shape: a licence may still carry its buyer's
// `email` until its next write drops it, and the indexes named by a plain SHA-256 of the address
// aren't read any more, so those few demo keys can't be recovered by e-mail.
//
// ponytail: Blob has no transactions. Each object is replaced whole, only over the version just read
// (ifMatch ETag, https://vercel.com/docs/vercel-blob/using-blob-sdk#put) with up to 5 tries, so two
// Macs activating at once can't pass the limit or drop each other; but a licence and its e-mail
// index are two writes (a failure in between leaves a key that recovery can't find), and a key
// written by 5+ Macs at the same instant answers 503. Move to Postgres or Redis if that ever matters.

/** The store when no Blob store is configured; tests read it. */
export const memory = new Map<string, { body: string; etag: string }>();
let version = 0;
const WRITE_TRIES = 5;
const BLOB_DEADLINE = 8_000;

function blobConfigured() {
  // The SDK signs in with OIDC + BLOB_STORE_ID (a store connected to the project) or BLOB_READ_WRITE_TOKEN.
  if (process.env.BLOB_READ_WRITE_TOKEN || process.env.BLOB_STORE_ID)
    return true;
  // A deployment without a store would hand out keys that vanish with the instance.
  if (process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development")
    throw new HttpError(503, NOT_SET_UP);
  return false;
}

/** One Blob SDK call with a deadline. The SDK retries 5xx and network errors itself (10 times by
 *  default, backing off), which could hold a request for minutes: at the deadline the call is
 *  aborted and the request answers 503. With an AbortError, which the SDK never retries; the
 *  TimeoutError of AbortSignal.timeout() it would. */
export async function blobCall<T>(
  call: (abortSignal: AbortSignal) => Promise<T>,
  ms = BLOB_DEADLINE,
): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      reject(new HttpError(503, BUSY)); // first, so the race ends with this whatever the abort does
      controller.abort();
    }, ms);
  });
  const pending = call(controller.signal);
  pending.catch(() => {}); // past the deadline, its failure has nowhere to go
  try {
    return await Promise.race([pending, deadline]);
  } finally {
    clearTimeout(timer);
  }
}

async function load<T>(
  path: string,
): Promise<{ value: T; etag: string } | null> {
  if (!blobConfigured()) {
    const hit = memory.get(path);
    return hit ? { value: JSON.parse(hit.body), etag: hit.etag } : null;
  }
  // useCache: false reads the latest write, not a CDN copy up to 60 s old:
  // https://vercel.com/docs/vercel-blob/private-storage#consistent-reads
  return blobCall(async (abortSignal) => {
    const result = await get(path, {
      access: "private",
      useCache: false,
      abortSignal,
    });
    if (result?.statusCode !== 200) return null;
    return {
      value: (await new Response(result.stream).json()) as T,
      etag: result.blob.etag,
    };
  });
}

/** Writes a new object when `etag` is null, else replaces exactly that version. */
async function save(path: string, value: unknown, etag: string | null) {
  const body = JSON.stringify(value);
  if (!blobConfigured()) {
    if ((memory.get(path)?.etag ?? null) !== etag)
      throw new BlobPreconditionFailedError();
    memory.set(path, { body, etag: String(++version) });
    return;
  }
  // A new object keeps allowOverwrite at its default (false); ifMatch implies it for an update.
  await blobCall((abortSignal) =>
    put(path, body, {
      access: "private",
      contentType: "application/json",
      ...(etag ? { ifMatch: etag } : {}),
      abortSignal,
    }),
  );
}

/** Read-modify-write: `change` returns the new value, or undefined to keep the current one (no write). */
async function update<T>(
  path: string,
  change: (current: T | null) => T | undefined,
) {
  for (let attempt = 1; ; attempt++) {
    const current = await load<T>(path);
    const next = change(current?.value ?? null);
    if (next === undefined) return current?.value ?? null;
    try {
      await save(path, next, current?.etag ?? null);
      return next;
    } catch (error) {
      // Lost to another writer (the ETag moved, or the object this was creating appeared): read
      // again, a few times. Anything else surfaces as is, and so does one race too many.
      const lost =
        error instanceof BlobPreconditionFailedError ||
        (!current &&
          error instanceof BlobError &&
          (await load(path).catch(() => null)) !== null);
      if (!lost) throw error;
      if (attempt === WRITE_TRIES) throw new HttpError(503, BUSY);
    }
  }
}

const licensePath = (key: string) => `licenses/${digest(key)}.json`;
const emailPath = (email: string) =>
  `emails/${hmac(email).toString("hex")}.json`;
/** ISO 8601 without fractional seconds, which the Mac app's JSONDecoder (.iso8601) reads. */
const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

/** Applies `change` to the licence for `key`; 404 when there is none. */
async function changeLicense(
  key: string,
  change: (license: License) => License | undefined,
) {
  const license = await update<License>(licensePath(key), (current) => {
    if (!current) throw new HttpError(404, "That license key doesn’t exist.");
    const next = change(current);
    // Spelled out, so an old record's `email` goes with this write.
    return (
      next && { key: next.key, created: next.created, devices: next.devices }
    );
  });
  return license as License;
}

/** Where `deviceId` sits on the key, in activation order; 403 unless it's one of the key's Macs. */
function position(license: License, deviceId: string) {
  const at = license.devices.findIndex((d) => d.id === deviceId);
  if (at === -1)
    throw new HttpError(403, "This Mac isn’t activated with that license.");
  return at;
}

/** The key's Macs as `self` sees them: itself under its own id, every other Mac under a handle. */
const listFor = (key: string, license: License, self: string) =>
  license.devices.map((d) =>
    d.id === self ? d : { ...d, id: handle(key, d.id) },
  );

/** The index with `key` added: once, and only while it lists fewer than 20 keys (checkout doesn't
 *  verify addresses, so anyone can name anyone's; the first keys stay). undefined when nothing
 *  changes, so there's nothing to write. */
export function withKey(index: EmailIndex | null, key: string) {
  const keys = [...new Set([...(index?.keys ?? []), key])].slice(0, EMAIL_KEYS);
  return index && keys.join() === index.keys.join() ? undefined : { keys };
}

// MARK: Abuse guard
// ponytail: counts live in this instance's memory, so every cap is per instance and resets on a cold
// start: N warm instances let N times as much through. Going global: a Vercel WAF rate-limit rule
// on /api/license/ for the per-address caps (https://vercel.com/docs/vercel-firewall/vercel-waf/rate-limiting)
// and @vercel/firewall's checkRateLimit with the key as rateLimitKey for the per-key one. The WAF's
// own 429 is safe for the Mac app, which takes nothing but this server's JSON as a verdict.

const hits = new Map<string, { count: number; reset: number }>();
/** activate, devices and deactivate, an hour: per network address, and per key. */
const MAC_CALLS_PER_IP = 120;
const MAC_CALLS_PER_KEY = 60;

/** 0 while `bucket` is within `max` an hour, else the seconds until it may go again. */
function throttled(bucket: string, max: number) {
  const time = Date.now();
  if (hits.size > 10_000)
    for (const [k, v] of hits) if (v.reset <= time) hits.delete(k);
  const hit = hits.get(bucket);
  if (!hit || hit.reset <= time) {
    hits.set(bucket, { count: 1, reset: time + HOUR });
    return 0;
  }
  return ++hit.count > max ? Math.ceil((hit.reset - time) / 1000) : 0;
}

/** A 503 with Retry-After once `bucket` is past `max`: a throttle is no verdict on a licence, and
 *  the Mac app treats every 503 as the server being unreachable. */
function limit(bucket: string, max: number) {
  const wait = throttled(bucket, max);
  if (wait)
    throw new HttpError(503, "Too many requests. Please try again later.", {
      "Retry-After": String(wait),
    });
}

function limitMac(request: Request, key: string) {
  limit(`mac:${clientIp(request)}`, MAC_CALLS_PER_IP);
  // Everyone shares the demo key, and it stores nothing.
  if (key !== DEMO_KEY) limit(`key:${key}`, MAC_CALLS_PER_KEY);
}

/** Vercel sets both to the caller's address, overwriting what the client sent:
 *  https://vercel.com/docs/headers/request-headers#x-forwarded-for */
const clientIp = (request: Request) =>
  request.headers.get("x-real-ip") ??
  request.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
  "local";

// MARK: Input

function text(value: unknown, name: string) {
  if (typeof value !== "string" || !value.trim())
    throw new HttpError(400, `Missing "${name}".`);
  // A lone surrogate is no text: it can't be stored or shown as it was sent.
  if (!value.isWellFormed())
    throw new HttpError(400, `"${name}" isn’t valid text.`);
  return value.trim();
}

function id(value: unknown, name: string) {
  const id = text(value, name);
  if (id.length > 100) throw new HttpError(400, `"${name}" is too long.`);
  return id;
}

/** The first `max` characters, counted in code points so an emoji is never cut in half. */
const clip = (value: string, max: number) =>
  Array.from(value).slice(0, max).join("");

/** Normalised like the app does: upper case, no spaces. */
function keyOf(body: Body) {
  const key = text(body.key, "key").toUpperCase().replace(/\s/g, "");
  if (!isValidKey(key))
    throw new HttpError(400, "That doesn’t look like an Isola license key.");
  return key;
}

function emailOf(value: unknown) {
  const email = text(value, "email").toLowerCase();
  if (email.length > 254 || !EMAIL.test(email))
    throw new HttpError(400, "That doesn’t look like an e-mail address.");
  return email;
}

/** The mailbox behind an address, for per-address caps: you+anything@example.com is you@example.com. */
const mailbox = (email: string) => email.replace(/\+[^@]*@/, "@");

/** Names and models are cut to 100 characters rather than refused: a long Mac name shouldn't block activation. */
function deviceOf(value: unknown) {
  const device = (value ?? {}) as Body;
  return {
    id: id(device.id, "device.id"),
    name: clip(text(device.name, "device.name"), 100),
    model: clip(text(device.model, "device.model"), 100),
  };
}

// MARK: Routes

async function demo(body: Body, request: Request) {
  const email =
    body.email == null || body.email === "" ? null : emailOf(body.email);
  limit(`demo:${clientIp(request)}`, 5);
  const key = mintKey();
  await save(
    licensePath(key),
    { key, created: now(), devices: [] } satisfies License,
    null,
  );
  if (email)
    await update<EmailIndex>(emailPath(email), (index) => withKey(index, key));
  return json({ key, email }, 201);
}

async function activate(body: Body, request: Request) {
  const key = keyOf(body);
  const device = deviceOf(body.device);
  limitMac(request, key);
  // The shared demo key stores no list, so one visitor never sees another's Macs.
  if (key === DEMO_KEY)
    return json({ devices: [{ ...device, activated: now() }] });
  const license = await changeLicense(key, (license) => {
    // A Mac already on the key just gets the list: a new name or model isn't worth a write.
    if (license.devices.some((d) => d.id === device.id)) return undefined;
    if (license.devices.length >= DEVICE_LIMIT)
      throw new HttpError(
        409,
        `This license is already active on ${DEVICE_LIMIT} Macs. Deactivate one first.`,
      );
    return {
      ...license,
      devices: [...license.devices, { ...device, activated: now() }],
    };
  });
  return json({ devices: listFor(key, license, device.id) });
}

async function devices(body: Body, request: Request) {
  const key = keyOf(body);
  const deviceId = id(body.deviceId, "deviceId");
  limitMac(request, key);
  if (key === DEMO_KEY) return json({ devices: [] });
  const license = (await load<License>(licensePath(key)))?.value;
  if (!license) throw new HttpError(404, "That license key doesn’t exist.");
  position(license, deviceId);
  return json({ devices: listFor(key, license, deviceId) });
}

/** A Mac removes itself (`target` is its own id) or a Mac activated after it (`target` is that Mac's
 *  handle): never an earlier one, so the first Mac on a key can always remove an intruder. */
async function deactivate(body: Body, request: Request) {
  const key = keyOf(body);
  const deviceId = id(body.deviceId, "deviceId");
  const target = id(body.target, "target");
  limitMac(request, key);
  if (key === DEMO_KEY) return json({ devices: [] });
  const license = await changeLicense(key, (license) => {
    const self = position(license, deviceId);
    const at =
      target === deviceId
        ? self
        : license.devices.findIndex((d) => handle(key, d.id) === target);
    if (at === -1) return undefined; // gone already
    if (at < self)
      throw new HttpError(
        403,
        "This Mac can’t remove a Mac that was activated before it. Deactivate it on that Mac, or from an earlier one.",
      );
    return {
      ...license,
      devices: license.devices.filter((_, i) => i !== at),
    };
  });
  return json({ devices: listFor(key, license, deviceId) });
}

/** Mail goes out through Resend only when both are set; that's configuration, not anyone's data. */
const mailConfigured = () =>
  Boolean(process.env.RESEND_API_KEY && process.env.RESEND_FROM);

async function recover(body: Body, request: Request) {
  const email = emailOf(body.email);
  limit(`recover:${clientIp(request)}`, 10);
  const mail = mailConfigured();
  // Answer before looking anything up: neither the reply nor its timing says whether the address has a licence.
  if (mail)
    waitUntil(
      sendLicenses(email).catch((error) =>
        console.error("license recovery failed:", error),
      ),
    );
  return json({ mail }, 202);
}

/** Mails the keys for `email` through Resend: https://resend.com/docs/api-reference/emails/send-email */
async function sendLicenses(email: string) {
  const { RESEND_API_KEY: apiKey, RESEND_FROM: from } = process.env;
  // At most 3 mails an hour per mailbox, whoever asks and whatever +tag they add (silently: the
  // reply never changes).
  if (!apiKey || !from || throttled(`mail:${digest(mailbox(email))}`, 3))
    return;
  const keys = (await load<EmailIndex>(emailPath(email)))?.value.keys ?? [];
  if (!keys.length) return;
  const many = keys.length > 1;
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      // Resend refuses requests without one (403, error 1010): https://resend.com/docs/knowledge-base/403-error-1010
      "User-Agent": "isola-license-server/1.0",
    },
    body: JSON.stringify({
      from,
      to: [email],
      subject: many ? "Your Isola licenses" : "Your Isola license",
      text: [
        many
          ? "Here are the Isola licenses for this address:"
          : "Here is your Isola license:",
        "",
        ...keys,
        "",
        `In Isola, open Settings › License, paste the key and click Activate. A license works on up to ${DEVICE_LIMIT} Macs.`,
        "",
        "Didn’t ask for this? You can ignore this e-mail.",
      ].join("\n"),
    }),
  });
  if (!response.ok)
    throw new Error(
      `Resend answered ${response.status}: ${await response.text()}`,
    );
}

const routes: Record<
  string,
  (body: Body, request: Request) => Promise<Response>
> = {
  demo,
  activate,
  devices,
  deactivate,
  recover,
};

function json(data: unknown, status = 200, headers?: Record<string, string>) {
  return Response.json(data, { status, headers });
}

export default {
  async fetch(request: Request) {
    // The vercel.json rewrite passes the action as ?action=; called directly, it's the last path segment.
    const url = new URL(request.url);
    const action =
      url.searchParams.get("action") ?? url.pathname.split("/").pop() ?? "";
    if (!Object.hasOwn(routes, action))
      return json({ error: "Not found." }, 404);
    if (request.method !== "POST")
      return json({ error: "Use POST." }, 405, { Allow: "POST" });
    // A form on another site can post text or form data without asking first; JSON from another
    // origin needs a CORS preflight, and this server sends no CORS headers, so it never passes.
    const type = request.headers.get("content-type")?.split(";")[0].trim();
    if (type?.toLowerCase() !== "application/json")
      return json(
        { error: "Send JSON (Content-Type: application/json)." },
        415,
      );
    try {
      secret(); // a production deployment without LICENSE_SECRET stops here, before any storage
      const body: unknown = await request.json().catch(() => null);
      if (typeof body !== "object" || body === null || Array.isArray(body))
        throw new HttpError(400, "Send a JSON object.");
      return await routes[action](body as Body, request);
    } catch (error) {
      if (error instanceof HttpError)
        return json({ error: error.message }, error.status, error.headers);
      console.error(error);
      return json({ error: "Something went wrong. Please try again." }, 500);
    }
  },
};
