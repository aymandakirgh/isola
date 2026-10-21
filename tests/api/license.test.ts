// The licence server's routes, offline: the function's handler called directly with an in-memory
// store and no mail. Run with `npm run test:api` (Node's own test runner, no Vercel credentials).
import assert from "node:assert/strict";
import { test } from "node:test";

// Whatever this shell's environment holds, never reach a real Blob store or Resend.
for (const name of [
  "BLOB_READ_WRITE_TOKEN",
  "BLOB_STORE_ID",
  "RESEND_API_KEY",
  "RESEND_FROM",
  "VERCEL_ENV",
])
  delete process.env[name];
const { default: api, isValidKey } = await import("../../api/license.ts");

type Listed = { devices: { id: string; activated: string }[] };
type Reply = Listed & { key: string; email: string | null; error: string };
const ids = (body: Listed) => body.devices.map((d) => d.id);
const mac = (id: string) => ({ id, name: `Mac ${id}`, model: "Mac16,1" });

let address = 0;
/** POST /api/license/<action>, from a new network address unless `from` is given (demo keys are capped per address). */
async function call(
  action: string,
  body: unknown,
  from = `198.51.100.${++address}`,
) {
  const response = await api.fetch(
    new Request(`http://localhost/api/license/${action}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-real-ip": from },
      body: JSON.stringify(body),
    }),
  );
  return {
    status: response.status,
    headers: response.headers,
    body: (await response.json()) as Reply,
  };
}

async function mint(email?: string): Promise<string> {
  const { status, body } = await call("demo", email ? { email } : {});
  assert.equal(status, 201);
  return body.key;
}

test("keys check out exactly as in the Mac app", () => {
  // License.makeKey(seed: 7) and License.makeKey(seed: 42), printed by the Swift code.
  assert.ok(isValidKey("ISOLA-W7UD-A389-NXLG"));
  assert.ok(isValidKey("ISOLA-52TY-ZEPC-VSK4"));
  assert.ok(!isValidKey("ISOLA-W7UD-A389-NXLH"), "a wrong checksum fails");
  assert.ok(!isValidKey("ISOLA-W7UD-A389"), "too short");
  assert.ok(isValidKey("ISOLA-DEMO-7Q4K-2M9X"), "the shared demo key");
});

test("demo mints a new key in the app's format", async () => {
  const withEmail = await call("demo", { email: " You@Example.com " });
  assert.equal(withEmail.status, 201);
  assert.match(
    withEmail.body.key,
    /^ISOLA-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/,
  );
  assert.ok(isValidKey(withEmail.body.key));
  assert.equal(withEmail.body.email, "you@example.com");
  const without = await call("demo", {});
  assert.equal(without.body.email, null);
  assert.notEqual(without.body.key, withEmail.body.key);
});

test("activate registers a Mac, and activating it again changes nothing", async () => {
  const key = await mint();
  const first = await call("activate", { key, device: mac("A") });
  assert.equal(first.status, 200);
  assert.deepEqual(ids(first.body), ["A"]);
  assert.match(
    first.body.devices[0].activated,
    /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
    "no fractional seconds",
  );
  const again = await call("activate", {
    key: ` ${key.toLowerCase()} `,
    device: mac("A"),
  });
  assert.equal(again.status, 200);
  assert.deepEqual(again.body, first.body);
});

test("a fourth Mac is refused with 409", async () => {
  const key = await mint();
  for (const id of ["A", "B", "C"])
    assert.equal(
      (await call("activate", { key, device: mac(id) })).status,
      200,
    );
  const fourth = await call("activate", { key, device: mac("D") });
  assert.equal(fourth.status, 409);
  assert.equal(
    fourth.body.error,
    "This license is already active on 3 Macs. Deactivate one first.",
  );
  assert.equal(
    (await call("activate", { key, device: mac("B") })).status,
    200,
    "a registered Mac still gets in",
  );
});

test("Macs activating at the same instant never pass the limit or drop each other", async () => {
  const key = await mint();
  const macs = ["A", "B", "C", "D", "E"];
  const results = await Promise.all(
    macs.map((id) => call("activate", { key, device: mac(id) })),
  );
  assert.deepEqual(
    results.map((r) => r.status).sort(),
    [200, 200, 200, 409, 409],
  );
  const winners = macs.filter((_, i) => results[i].status === 200);
  const listed = await call("devices", { key, deviceId: winners[0] });
  assert.deepEqual(ids(listed.body).sort(), winners);
});

test("devices answers only a Mac registered on that key", async () => {
  const key = await mint();
  await call("activate", { key, device: mac("A") });
  const listed = await call("devices", { key, deviceId: "A" });
  assert.equal(listed.status, 200);
  assert.deepEqual(ids(listed.body), ["A"]);
  assert.equal((await call("devices", { key, deviceId: "B" })).status, 403);
  const unminted = await call("devices", {
    key: "ISOLA-W7UD-A389-NXLG",
    deviceId: "A",
  });
  assert.equal(
    unminted.status,
    404,
    "a well-formed key the server never minted",
  );
});

test("deactivate removes another Mac, asked by a registered one", async () => {
  const key = await mint();
  for (const id of ["A", "B", "C"])
    await call("activate", { key, device: mac(id) });
  assert.equal(
    (await call("deactivate", { key, deviceId: "Z", target: "B" })).status,
    403,
  );
  const removed = await call("deactivate", { key, deviceId: "A", target: "B" });
  assert.equal(removed.status, 200);
  assert.deepEqual(ids(removed.body), ["A", "C"]);
  assert.equal(
    (await call("devices", { key, deviceId: "B" })).status,
    403,
    "the removed Mac is out",
  );
  assert.equal(
    (await call("activate", { key, device: mac("D") })).status,
    200,
    "and its slot is free",
  );
  const itself = await call("deactivate", { key, deviceId: "C", target: "C" });
  assert.deepEqual(ids(itself.body), ["A", "D"]);
});

test("the shared demo key has no device limit and keeps no list", async () => {
  const key = "ISOLA-DEMO-7Q4K-2M9X";
  for (const id of ["A", "B", "C", "D", "E"]) {
    const { status, body } = await call("activate", { key, device: mac(id) });
    assert.equal(status, 200);
    assert.deepEqual(ids(body), [id], "each Mac sees only itself");
  }
  assert.deepEqual((await call("devices", { key, deviceId: "A" })).body, {
    devices: [],
  });
});

test("recover answers the same 202 whether or not the address has a license", async (t) => {
  const key = await mint("known@example.com");
  const known = await call("recover", { email: "Known@Example.com" });
  const unknown = await call("recover", { email: "nobody@example.com" });
  assert.equal(known.status, 202);
  assert.deepEqual(known.body, unknown.body);
  assert.equal(
    known.headers.get("content-length"),
    unknown.headers.get("content-length"),
  );

  // With Resend configured (fetch stubbed, so nothing leaves this process) only the known address gets mail.
  const sent: { url: string; init?: RequestInit }[] = [];
  t.mock.method(
    globalThis,
    "fetch",
    async (url: string | URL | Request, init?: RequestInit) => {
      sent.push({ url: String(url), init });
      return Response.json({ id: "stub" });
    },
  );
  process.env.RESEND_API_KEY = "re_test";
  process.env.RESEND_FROM = "Isola <licenses@example.com>";
  t.after(() => {
    delete process.env.RESEND_API_KEY;
    delete process.env.RESEND_FROM;
  });
  assert.equal(
    (await call("recover", { email: "nobody@example.com" })).status,
    202,
  );
  assert.equal(
    (await call("recover", { email: "known@example.com" })).status,
    202,
  );
  await new Promise((resolve) => setTimeout(resolve, 50)); // the mail goes out after the reply
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, "https://api.resend.com/emails");
  const headers = new Headers(sent[0].init?.headers);
  assert.equal(headers.get("authorization"), "Bearer re_test");
  assert.ok(headers.get("user-agent"));
  const mail = JSON.parse(String(sent[0].init?.body));
  assert.deepEqual(mail.to, ["known@example.com"]);
  assert.equal(mail.from, "Isola <licenses@example.com>");
  assert.ok(mail.text.includes(key));
});

test("demo keys are capped per network address", async () => {
  const from = "203.0.113.9";
  for (let i = 0; i < 5; i++)
    assert.equal((await call("demo", {}, from)).status, 201);
  const capped = await call("demo", {}, from);
  assert.equal(capped.status, 429);
  assert.ok(Number(capped.headers.get("retry-after")) > 0);
  assert.equal(
    (await call("demo", {})).status,
    201,
    "another address still gets one",
  );
});

test("bad requests get a plain 4xx and no internals", async () => {
  const raw = (path: string, init?: RequestInit) =>
    api.fetch(new Request(`http://localhost${path}`, init));
  const malformed = await raw("/api/license/activate", {
    method: "POST",
    body: "{nope",
  });
  assert.equal(malformed.status, 400);
  assert.deepEqual(Object.keys((await malformed.json()) as object), ["error"]);
  assert.equal(
    (await raw("/api/license/activate", { method: "POST", body: "[]" })).status,
    400,
  );
  assert.equal(
    (await call("activate", { key: "ISOLA-NOPE", device: mac("A") })).status,
    400,
  );
  assert.equal(
    (await call("activate", { key: "ISOLA-W7UD-A389-NXLG" })).status,
    400,
    "no device",
  );
  assert.equal(
    (
      await call("activate", {
        key: "ISOLA-W7UD-A389-NXLG",
        device: { ...mac("A"), id: "x".repeat(101) },
      })
    ).status,
    400,
  );
  assert.equal(
    (await call("activate", { key: "ISOLA-W7UD-A389-NXLG", device: mac("A") }))
      .status,
    404,
  );
  assert.equal((await call("demo", { email: "nope" })).status, 400);
  assert.equal((await call("recover", { email: "nope" })).status, 400);
  assert.equal((await call("nope", {})).status, 404);
  assert.equal(
    (await call("constructor", {})).status,
    404,
    "no prototype keys as routes",
  );
  const get = await raw("/api/license/demo");
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");
  // The vercel.json rewrite's form of the same route.
  const rewritten = await raw("/api/license?action=demo", {
    method: "POST",
    body: "{}",
    headers: { "x-real-ip": "192.0.2.1" },
  });
  assert.equal(rewritten.status, 201);
});

test("a deployment without a Blob store answers 503 rather than keep keys in memory", async (t) => {
  process.env.VERCEL_ENV = "production";
  t.after(() => {
    delete process.env.VERCEL_ENV;
  });
  const { status, body } = await call("demo", {});
  assert.equal(status, 503);
  assert.equal(
    body.error,
    "The license server isn’t set up yet. Please try again later.",
  );
});
