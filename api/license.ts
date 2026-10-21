// Isola licence server: one Vercel Function (Node.js runtime, Web-standard `fetch` export) for every
// /api/license/<action> route; vercel.json rewrites them here, as Vercel recommends for a non-Next.js
// /api (one shared function routed by path): https://vercel.com/docs/functions/runtimes/node-js
//
//   POST /api/license/demo        {email?}                          → 201 {key, email}
//   POST /api/license/activate    {key, device: {id, name, model}}  → 200 {devices}  (409 past 3 Macs)
//   POST /api/license/devices     {key, deviceId}                   → 200 {devices}  (403 unless deviceId is on the key)
//   POST /api/license/deactivate  {key, deviceId, target}           → 200 {devices}
//   POST /api/license/recover     {email}                           → 202 {}         (same for every address)
//
// Errors are {error} with a sentence the Mac app shows as is. Payments stay a no-charge demo.
import { createHash, randomInt } from "node:crypto";
import { BlobPreconditionFailedError, get, put } from "@vercel/blob";
import { waitUntil } from "@vercel/functions";

/** Same alphabet and checksum as the Mac app: mac/Sources/Isola/Modules/Settings/License.swift. */
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/** The website's public demo key: valid everywhere, no device limit, and no stored device list. */
const DEMO_KEY = "ISOLA-DEMO-7Q4K-2M9X";
const DEVICE_LIMIT = 3;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const HOUR = 3_600_000;

type Device = { id: string; name: string; model: string; activated: string };
type License = {
  key: string;
  email: string | null;
  created: string;
  devices: Device[];
};
type EmailIndex = { keys: string[] };
type Body = Record<string, unknown>;

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
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

// MARK: Storage: one private JSON object per licence, named by a hash of its key, and one per e-mail
// address listing its keys, named by a hash of the address. Vercel Blob in a private store
// (https://vercel.com/docs/vercel-blob/private-storage) or, with no store configured (local runs,
// tests), this process's memory.
//
// ponytail: Blob has no transactions. Each object is replaced whole, only over the version just read
// (ifMatch ETag, https://vercel.com/docs/vercel-blob/using-blob-sdk#put) with up to 5 tries, so two
// Macs activating at once can't pass the limit or drop each other; but a licence and its e-mail
// index are two writes (a failure in between leaves a key that recovery can't find), and a key
// written by 5+ Macs at the same instant gives up. Move to Postgres or Redis if that ever matters.

const memory = new Map<string, { body: string; etag: string }>();
let version = 0;

function blobConfigured() {
  // The SDK signs in with OIDC + BLOB_STORE_ID (a store connected to the project) or BLOB_READ_WRITE_TOKEN.
  if (process.env.BLOB_READ_WRITE_TOKEN || process.env.BLOB_STORE_ID)
    return true;
  // A deployment without a store would hand out keys that vanish with the instance.
  if (process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development")
    throw new HttpError(
      503,
      "The license server isn’t set up yet. Please try again later.",
    );
  return false;
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
  const result = await get(path, { access: "private", useCache: false });
  if (result?.statusCode !== 200) return null;
  return {
    value: (await new Response(result.stream).json()) as T,
    etag: result.blob.etag,
  };
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
  await put(path, body, {
    access: "private",
    contentType: "application/json",
    ...(etag ? { ifMatch: etag } : {}),
  });
}

/** Read-modify-write: `change` returns the new value, or undefined to keep the current one. */
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
      // Someone wrote in between (ETag mismatch, or a create that found the object there): read again.
      if (
        attempt === 5 ||
        !(error instanceof BlobPreconditionFailedError || !current)
      )
        throw error;
    }
  }
}

const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const licensePath = (key: string) => `licenses/${digest(key)}.json`;
const emailPath = (email: string) => `emails/${digest(email)}.json`;
/** ISO 8601 without fractional seconds, which the Mac app's JSONDecoder (.iso8601) reads. */
const now = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

/** Applies `change` to the licence for `key`; 404 when there is none. */
async function changeLicense(
  key: string,
  change: (license: License) => License | undefined,
) {
  const license = await update<License>(licensePath(key), (current) => {
    if (!current) throw new HttpError(404, "That license key doesn’t exist.");
    return change(current);
  });
  return license as License;
}

function registered(license: License, deviceId: string) {
  if (!license.devices.some((d) => d.id === deviceId))
    throw new HttpError(403, "This Mac isn’t activated with that license.");
}

// MARK: Abuse guard
// ponytail: counts live in this instance's memory, so a cap is per instance and resets on a cold
// start; a Vercel WAF rate-limit rule (or a shared counter) makes it global.

const hits = new Map<string, { count: number; reset: number }>();

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

/** Vercel sets both to the caller's address, overwriting what the client sent:
 *  https://vercel.com/docs/headers/request-headers#x-forwarded-for */
const clientIp = (request: Request) =>
  request.headers.get("x-real-ip") ??
  request.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
  "local";

const tooMany = (seconds: number) =>
  json(
    { error: "Too many requests from this network. Please try again later." },
    429,
    { "Retry-After": String(seconds) },
  );

// MARK: Input

function text(value: unknown, name: string) {
  if (typeof value !== "string" || !value.trim())
    throw new HttpError(400, `Missing "${name}".`);
  return value.trim();
}

function id(value: unknown, name: string) {
  const id = text(value, name);
  if (id.length > 100) throw new HttpError(400, `"${name}" is too long.`);
  return id;
}

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

/** Names and models are cut to 100 characters rather than refused: a long Mac name shouldn't block activation. */
function deviceOf(value: unknown) {
  const device = (value ?? {}) as Body;
  return {
    id: id(device.id, "device.id"),
    name: text(device.name, "device.name").slice(0, 100),
    model: text(device.model, "device.model").slice(0, 100),
  };
}

// MARK: Routes

async function demo(body: Body, request: Request) {
  const email =
    body.email == null || body.email === "" ? null : emailOf(body.email);
  const wait = throttled(`demo:${clientIp(request)}`, 5);
  if (wait) return tooMany(wait);
  const key = mintKey();
  await save(
    licensePath(key),
    { key, email, created: now(), devices: [] } satisfies License,
    null,
  );
  if (email)
    await update<EmailIndex>(emailPath(email), (index) => ({
      keys: [...(index?.keys ?? []), key],
    }));
  return json({ key, email }, 201);
}

async function activate(body: Body) {
  const key = keyOf(body);
  const device = deviceOf(body.device);
  // The shared demo key stores no list, so one visitor never sees another's Macs.
  if (key === DEMO_KEY)
    return json({ devices: [{ ...device, activated: now() }] });
  const license = await changeLicense(key, (license) => {
    const known = license.devices.find((d) => d.id === device.id);
    if (known) {
      if (known.name === device.name && known.model === device.model)
        return undefined;
      return {
        ...license,
        devices: license.devices.map((d) =>
          d === known ? { ...d, ...device } : d,
        ),
      };
    }
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
  return json({ devices: license.devices });
}

async function devices(body: Body) {
  const key = keyOf(body);
  const deviceId = id(body.deviceId, "deviceId");
  if (key === DEMO_KEY) return json({ devices: [] });
  const license = (await load<License>(licensePath(key)))?.value;
  if (!license) throw new HttpError(404, "That license key doesn’t exist.");
  registered(license, deviceId);
  return json({ devices: license.devices });
}

async function deactivate(body: Body) {
  const key = keyOf(body);
  const deviceId = id(body.deviceId, "deviceId");
  const target = id(body.target, "target");
  if (key === DEMO_KEY) return json({ devices: [] });
  const license = await changeLicense(key, (license) => {
    registered(license, deviceId);
    if (!license.devices.some((d) => d.id === target)) return undefined;
    return {
      ...license,
      devices: license.devices.filter((d) => d.id !== target),
    };
  });
  return json({ devices: license.devices });
}

async function recover(body: Body, request: Request) {
  const email = emailOf(body.email);
  const wait = throttled(`recover:${clientIp(request)}`, 10);
  if (wait) return tooMany(wait);
  // Answer before looking anything up: neither the reply nor its timing says whether the address has a licence.
  waitUntil(
    sendLicenses(email).catch((error) =>
      console.error("license recovery failed:", error),
    ),
  );
  return json({}, 202);
}

/** Mails the keys for `email` through Resend, only when RESEND_API_KEY and RESEND_FROM are set:
 *  https://resend.com/docs/api-reference/emails/send-email */
async function sendLicenses(email: string) {
  const { RESEND_API_KEY: apiKey, RESEND_FROM: from } = process.env;
  // At most 3 mails an hour per address, whoever asks (silently: the reply never changes).
  if (!apiKey || !from || throttled(`mail:${digest(email)}`, 3)) return;
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
    try {
      const body: unknown = await request.json().catch(() => null);
      if (typeof body !== "object" || body === null || Array.isArray(body))
        throw new HttpError(400, "Send a JSON object.");
      return await routes[action](body as Body, request);
    } catch (error) {
      if (error instanceof HttpError)
        return json({ error: error.message }, error.status);
      console.error(error);
      return json({ error: "Something went wrong. Please try again." }, 500);
    }
  },
};
