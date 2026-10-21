// The licence server's routes, offline: the function's handler called directly with an in-memory
// store and no mail. Run with `npm run test:api` (Node's own test runner, no Vercel credentials).
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import { test, type TestContext } from "node:test";

// Whatever this shell's environment holds, never reach a real Blob store or Resend, and use the
// built-in development secret.
for (const name of [
  "BLOB_READ_WRITE_TOKEN",
  "BLOB_STORE_ID",
  "RESEND_API_KEY",
  "RESEND_FROM",
  "VERCEL_ENV",
  "LICENSE_SECRET",
])
  delete process.env[name];
const {
  default: api,
  isValidKey,
  memory,
  withKey,
  withDeadline,
} = await import("../../api/license.ts");

type Listed = {
  devices: { id: string; name: string; activated: string; lastSeen: string }[];
};
type Reply = Listed & {
  key: string;
  email: string | null;
  error: string;
  code?: string;
  mail: boolean;
};
const ids = (body: Listed) => body.devices.map((d) => d.id);
/** A Mac whose id (its credential) is distinctive enough to spot anywhere in a reply. */
const mac = (name: string) => ({
  id: `${name}-device-id`,
  name: `Mac ${name}`,
  model: "Mac16,1",
});
const HANDLE = /^[A-Za-z0-9_-]{22}$/;
const sha256 = (value: string) =>
  createHash("sha256").update(value).digest("hex");
const hmac = (secret: string, value: string) =>
  createHmac("sha256", secret).update(value).digest();

let address = 0;
/** POST /api/license/<action>, from a new network address unless `from` is given (most routes cap per address). */
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

async function activateAll(key: string, names: string[]) {
  for (const name of names)
    assert.equal(
      (await call("activate", { key, device: mac(name) })).status,
      200,
    );
}

/** Every stored object's ETag: what changes is what was written. */
const versions = () =>
  new Map([...memory].map(([path, { etag }]) => [path, etag]));

let rewrites = 0;
/** Changes the stored licence for `key` behind the server's back: time passing, or an old record. */
function rewrite(
  key: string,
  change: (license: { devices: Record<string, string>[] }) => void,
) {
  const path = `licenses/${sha256(key)}.json`;
  const license = JSON.parse(memory.get(path)!.body);
  change(license);
  memory.set(path, {
    body: JSON.stringify(license),
    etag: `rewritten-${++rewrites}`,
  });
}
/** A stored date, `days` ago. */
const daysAgo = (days: number) =>
  new Date(Date.now() - days * 86_400_000)
    .toISOString()
    .replace(/\.\d+Z$/, "Z");
const justNow = (date: string) => Date.now() - Date.parse(date) < 60_000;

/** Resend configured for this test, with fetch stubbed so nothing leaves the process. */
function mailbox(
  t: TestContext,
  respond = async (_init?: RequestInit) => Response.json({ id: "stub" }),
) {
  const sent: { url: string; init?: RequestInit }[] = [];
  t.mock.method(
    globalThis,
    "fetch",
    async (url: string | URL | Request, init?: RequestInit) => {
      sent.push({ url: String(url), init });
      return respond(init);
    },
  );
  process.env.RESEND_API_KEY = "re_test";
  process.env.RESEND_FROM = "Isola <licenses@example.com>";
  t.after(() => {
    delete process.env.RESEND_API_KEY;
    delete process.env.RESEND_FROM;
  });
  return sent;
}
/** The mail goes out after the reply. */
const delivered = () => new Promise((resolve) => setTimeout(resolve, 50));

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

test("activate registers a Mac; activating it again writes nothing, even with a new name", async () => {
  const key = await mint();
  const first = await call("activate", { key, device: mac("a") });
  assert.equal(first.status, 200);
  assert.deepEqual(ids(first.body), [mac("a").id]);
  assert.match(
    first.body.devices[0].activated,
    /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
    "no fractional seconds",
  );
  assert.equal(
    first.body.devices[0].lastSeen,
    first.body.devices[0].activated,
    "seen as it's activated",
  );
  const before = versions();
  const again = await call("activate", {
    key: ` ${key.toLowerCase()} `,
    device: { ...mac("a"), name: "Renamed", model: "Mac99,1" },
  });
  assert.equal(again.status, 200);
  assert.deepEqual(again.body, first.body, "the stored Mac, unchanged");
  assert.deepEqual(versions(), before, "no write");
});

test("a fourth Mac is refused with 409", async () => {
  const key = await mint();
  await activateAll(key, ["a", "b", "c"]);
  const fourth = await call("activate", { key, device: mac("d") });
  assert.equal(fourth.status, 409);
  assert.equal(
    fourth.body.error,
    "This license is already active on 3 Macs. Deactivate one first.",
  );
  assert.equal(
    (await call("activate", { key, device: mac("b") })).status,
    200,
    "a registered Mac still gets in",
  );
});

test("Macs activating at the same instant never pass the limit or drop each other", async () => {
  const key = await mint();
  const names = ["a", "b", "c", "d", "e"];
  const results = await Promise.all(
    names.map((name) => call("activate", { key, device: mac(name) })),
  );
  assert.deepEqual(
    results.map((r) => r.status).sort(),
    [200, 200, 200, 409, 409],
  );
  for (const [i, name] of names.entries()) {
    const listed = await call("devices", { key, deviceId: mac(name).id });
    assert.equal(
      listed.status,
      results[i].status === 200 ? 200 : 403,
      "the winners are on the key, the others aren't",
    );
    if (listed.status === 200) assert.equal(listed.body.devices.length, 3);
  }
});

test("devices answers only a Mac registered on that key", async () => {
  const key = await mint();
  await activateAll(key, ["a"]);
  const listed = await call("devices", { key, deviceId: mac("a").id });
  assert.equal(listed.status, 200);
  assert.deepEqual(ids(listed.body), [mac("a").id]);
  assert.equal(
    (await call("devices", { key, deviceId: mac("b").id })).status,
    403,
  );
  const unminted = await call("devices", {
    key: "ISOLA-W7UD-A389-NXLG",
    deviceId: mac("a").id,
  });
  assert.equal(
    unminted.status,
    404,
    "a well-formed key the server never minted",
  );
});

test("a Mac sees its own id and only opaque handles for the others", async () => {
  const key = await mint();
  await activateAll(key, ["alpha", "bravo", "charlie"]);
  const asAlpha = (await call("devices", { key, deviceId: mac("alpha").id }))
    .body;
  const asBravo = (await call("devices", { key, deviceId: mac("bravo").id }))
    .body;
  assert.equal(asAlpha.devices[0].id, mac("alpha").id);
  assert.equal(asBravo.devices[1].id, mac("bravo").id);
  for (const other of [asAlpha.devices[1], asAlpha.devices[2]])
    assert.match(other.id, HANDLE);
  assert.equal(
    asAlpha.devices[2].id,
    asBravo.devices[2].id,
    "a Mac's handle is the same whoever asks",
  );
  for (const raw of [mac("bravo").id, mac("charlie").id])
    assert.ok(
      !JSON.stringify(asAlpha).includes(raw),
      "no other Mac's id in the reply",
    );
  const activated = await call("activate", { key, device: mac("charlie") });
  assert.deepEqual(
    ids(activated.body),
    [asBravo.devices[0].id, asAlpha.devices[1].id, mac("charlie").id],
    "activate answers the same way",
  );

  // deactivate takes a handle: another Mac's raw id matches nothing.
  const byId = await call("deactivate", {
    key,
    deviceId: mac("alpha").id,
    target: mac("charlie").id,
  });
  assert.equal(byId.status, 200);
  assert.equal(byId.body.devices.length, 3);
  const byHandle = await call("deactivate", {
    key,
    deviceId: mac("alpha").id,
    target: asAlpha.devices[2].id,
  });
  assert.deepEqual(ids(byHandle.body), ids(asAlpha).slice(0, 2));
  assert.equal(
    (await call("devices", { key, deviceId: mac("charlie").id })).status,
    403,
    "the removed Mac is out",
  );
  assert.equal(
    (await call("activate", { key, device: mac("delta") })).status,
    200,
    "and its slot is free",
  );
});

test("a Mac can remove itself or a Mac activated after it, never an earlier one", async () => {
  const key = await mint();
  await activateAll(key, ["first", "second", "third"]);
  const seen = (await call("devices", { key, deviceId: mac("third").id })).body
    .devices;
  const refused = await call("deactivate", {
    key,
    deviceId: mac("third").id,
    target: seen[0].id,
  });
  assert.equal(refused.status, 403);
  assert.equal(refused.body.code, "order");
  assert.match(refused.body.error, /activated before it/);
  assert.equal(
    (await call("devices", { key, deviceId: mac("first").id })).body.devices
      .length,
    3,
    "nothing removed",
  );
  assert.equal(
    (
      await call("deactivate", {
        key,
        deviceId: mac("third").id,
        target: seen[1].id,
      })
    ).status,
    403,
    "the second Mac is earlier too",
  );
  assert.equal(
    (
      await call("deactivate", {
        key,
        deviceId: mac("zulu").id,
        target: seen[2].id,
      })
    ).status,
    403,
    "a Mac not on the key removes nothing",
  );

  // The first Mac clears out the later ones; a Mac can always remove itself.
  const asFirst = (await call("devices", { key, deviceId: mac("first").id }))
    .body.devices;
  const cleared = await call("deactivate", {
    key,
    deviceId: mac("first").id,
    target: asFirst[2].id,
  });
  assert.deepEqual(ids(cleared.body), ids({ devices: asFirst }).slice(0, 2));
  const itself = await call("deactivate", {
    key,
    deviceId: mac("second").id,
    target: mac("second").id,
  });
  assert.equal(itself.status, 200);
  assert.equal(itself.body.devices.length, 1);
  assert.match(itself.body.devices[0].id, HANDLE, "it's off the list it gets");
});

test("activate and devices note when a Mac was last seen, writing at most once a day", async () => {
  const key = await mint();
  await activateAll(key, ["a", "b"]);
  const before = versions();
  await call("devices", { key, deviceId: mac("a").id });
  await call("activate", { key, device: mac("a") });
  assert.deepEqual(versions(), before, "seen again the same day: no write");

  rewrite(key, (license) => {
    license.devices[0].lastSeen = daysAgo(2);
  });
  const listed = await call("devices", { key, deviceId: mac("a").id });
  assert.ok(
    justNow(listed.body.devices[0].lastSeen),
    "a day on, devices notes it",
  );
  assert.ok(justNow(listed.body.devices[0].activated), "activation stays");
  const after = versions();
  await call("devices", { key, deviceId: mac("a").id });
  assert.deepEqual(versions(), after, "and not again that day");
  rewrite(key, (license) => {
    license.devices[0].lastSeen = daysAgo(2);
  });
  const activated = await call("activate", { key, device: mac("a") });
  assert.ok(justNow(activated.body.devices[0].lastSeen), "so does activate");

  // A record from before lastSeen: its activation date stands in, in the list too.
  rewrite(key, (license) => {
    delete license.devices[0].lastSeen;
    license.devices[0].activated = daysAgo(3);
  });
  const asB = await call("devices", { key, deviceId: mac("b").id });
  assert.equal(asB.body.devices[0].lastSeen, asB.body.devices[0].activated);
  assert.ok(!justNow(asB.body.devices[0].lastSeen));
});

test("any Mac on the key can remove a Mac not seen for 30 days", async () => {
  const key = await mint();
  await activateAll(key, ["first", "second", "third"]);
  const seen = (await call("devices", { key, deviceId: mac("third").id })).body
    .devices;
  const removeFirst = () =>
    call("deactivate", {
      key,
      deviceId: mac("third").id,
      target: seen[0].id,
    });
  rewrite(key, (license) => {
    license.devices[0].lastSeen = daysAgo(29);
  });
  const refused = await removeFirst();
  assert.equal(refused.status, 403, "29 days isn't long enough");
  assert.equal(refused.body.code, "order");
  rewrite(key, (license) => {
    license.devices[0].lastSeen = daysAgo(31);
  });
  const removed = await removeFirst();
  assert.equal(removed.status, 200);
  assert.deepEqual(ids(removed.body), [seen[1].id, mac("third").id]);

  // A record from before lastSeen goes by its activation date.
  rewrite(key, (license) => {
    delete license.devices[0].lastSeen;
    license.devices[0].activated = daysAgo(40);
  });
  const old = await call("deactivate", {
    key,
    deviceId: mac("third").id,
    target: seen[1].id,
  });
  assert.equal(old.status, 200);
  assert.deepEqual(ids(old.body), [mac("third").id]);
  assert.equal(
    (await call("devices", { key, deviceId: mac("first").id })).body.code,
    "not_on_key",
    "the removed Mac hears it at its next sync",
  );
});

test("every verdict on a licence carries a code, and nothing else does", async () => {
  const key = await mint();
  await activateAll(key, ["a", "b", "c"]);
  const asC = (await call("devices", { key, deviceId: mac("c").id })).body
    .devices;
  const unminted = "ISOLA-W7UD-A389-NXLG";
  for (const [reply, status, code] of [
    [await call("devices", { key, deviceId: mac("z").id }), 403, "not_on_key"],
    [
      await call("deactivate", {
        key,
        deviceId: mac("z").id,
        target: mac("z").id,
      }),
      403,
      "not_on_key",
    ],
    [
      await call("devices", { key: unminted, deviceId: mac("a").id }),
      404,
      "unknown_key",
    ],
    [
      await call("activate", { key: unminted, device: mac("a") }),
      404,
      "unknown_key",
    ],
    [await call("activate", { key, device: mac("d") }), 409, "limit"],
    [
      await call("deactivate", {
        key,
        deviceId: mac("c").id,
        target: asC[0].id,
      }),
      403,
      "order",
    ],
  ] as const) {
    assert.equal(reply.status, status, code);
    assert.equal(reply.body.code, code);
    assert.deepEqual(Object.keys(reply.body).sort(), ["code", "error"]);
  }
  for (const reply of [
    await call("activate", { key: "ISOLA-NOPE", device: mac("a") }),
    await call("devices", { key, deviceId: "x".repeat(101) }),
    await call("nope", {}),
  ])
    assert.deepEqual(Object.keys(reply.body), ["error"], String(reply.status));
});

test("the shared demo key has no device limit and keeps no list", async () => {
  const key = "ISOLA-DEMO-7Q4K-2M9X";
  for (const name of ["a", "b", "c", "d", "e"]) {
    const { status, body } = await call("activate", { key, device: mac(name) });
    assert.equal(status, 200);
    assert.deepEqual(ids(body), [mac(name).id], "each Mac sees only itself");
  }
  assert.deepEqual(
    (await call("devices", { key, deviceId: mac("a").id })).body,
    { devices: [] },
  );
});

test("recover answers the same 202 whatever the address; {mail} only says whether mail is set up", async (t) => {
  const key = await mint("known@example.com");
  const known = await call("recover", { email: "Known@Example.com" });
  const unknown = await call("recover", { email: "nobody@example.com" });
  assert.equal(known.status, 202);
  assert.deepEqual(known.body, { mail: false });
  assert.deepEqual(unknown.body, known.body);
  assert.equal(
    known.headers.get("content-length"),
    unknown.headers.get("content-length"),
  );

  const sent = mailbox(t);
  const asked = await Promise.all(
    ["nobody@example.com", "known@example.com"].map((email) =>
      call("recover", { email }),
    ),
  );
  for (const { status, body } of asked) {
    assert.equal(status, 202);
    assert.deepEqual(body, { mail: true });
  }
  await delivered();
  assert.equal(sent.length, 1, "only the known address gets mail");
  assert.equal(sent[0].url, "https://api.resend.com/emails");
  const headers = new Headers(sent[0].init?.headers);
  assert.equal(headers.get("authorization"), "Bearer re_test");
  assert.ok(headers.get("user-agent"));
  const mail = JSON.parse(String(sent[0].init?.body));
  assert.deepEqual(mail.to, ["known@example.com"]);
  assert.equal(mail.from, "Isola <licenses@example.com>");
  assert.ok(mail.text.includes(key));
});

test("only a plain e-mail address is taken, lower-cased", async () => {
  for (const email of [
    "nope",
    '"a b"@example.com',
    '"a"@example.com',
    "<a@example.com>",
    "Name <a@example.com>",
    "a@example.com, b@example.com",
    "a@example.com,b@example.com",
    "a@example.com;b@example.com",
    "a b@example.com",
    "a@exam ple.com",
    "a\n@example.com",
    "a@example",
    "a@@example.com",
    "a..b@example.com",
    "a@example..com",
    "a@-example.com",
    "à@example.com",
    `${"a".repeat(243)}@example.com`,
  ]) {
    assert.equal((await call("recover", { email })).status, 400, email);
    assert.equal((await call("demo", { email })).status, 400, email);
  }
  const ok = await call("demo", { email: " You+Shop@Example.COM " });
  assert.equal(ok.status, 201);
  assert.equal(ok.body.email, "you+shop@example.com");
  assert.equal(
    (await call("recover", { email: `${"a".repeat(242)}@example.com` })).status,
    202,
    "254 characters is the most",
  );
});

test("mail goes out at most 3 times an hour per mailbox, +tags included", async (t) => {
  const tags = ["", "+a", "+b", "+c"];
  for (const tag of tags) await mint(`capped${tag}@example.com`);
  await mint("other@example.com");
  const sent = mailbox(t);
  for (const tag of tags)
    assert.equal(
      (await call("recover", { email: `capped${tag}@example.com` })).status,
      202,
    );
  await call("recover", { email: "other@example.com" });
  await delivered();
  const to = sent.map((s) => JSON.parse(String(s.init?.body)).to[0]).sort();
  assert.deepEqual(to, [
    "capped+a@example.com",
    "capped+b@example.com",
    "capped@example.com",
    "other@example.com",
  ]);
});

test("an address lists each key once, the 20 most recent, and its index is rewritten only when that changes", async () => {
  assert.deepEqual(withKey(null, "K1"), { keys: ["K1"] });
  assert.equal(withKey({ keys: ["K1"] }, "K1"), undefined, "already there");
  assert.deepEqual(withKey({ keys: ["K1", "K1", "K2"] }, "K3"), {
    keys: ["K1", "K2", "K3"],
  });
  const twenty = Array.from({ length: 20 }, (_, i) => `K${i}`);
  assert.deepEqual(
    withKey({ keys: twenty }, "K20"),
    { keys: [...twenty.slice(1), "K20"] },
    "full: the oldest goes",
  );
  assert.deepEqual(withKey({ keys: [...twenty, "K20"] }, "K21"), {
    keys: [...twenty.slice(2), "K20", "K21"],
  });

  const email = "many@example.com";
  const keys: string[] = [];
  for (let i = 0; i < 21; i++) keys.push(await mint(email));
  const [, index] = [...memory].find(
    ([path, { body }]) => path.startsWith("emails/") && body.includes(keys[20]),
  )!;
  assert.deepEqual(
    JSON.parse(index.body),
    { keys: keys.slice(1) },
    "the 21st key pushes out the first",
  );
});

test("no stored object holds an e-mail address, and index names are HMACs of it", async (t) => {
  process.env.LICENSE_SECRET = "test-secret";
  t.after(() => {
    delete process.env.LICENSE_SECRET;
  });
  const email = "private.person@example.com";
  const key = await mint(email);
  for (const [path, { body }] of memory)
    assert.ok(!body.includes(email), `${path} holds the address`);
  assert.ok(
    memory.has(`emails/${hmac("test-secret", email).toString("hex")}.json`),
  );
  assert.ok(!memory.has(`emails/${sha256(email)}.json`), "not a plain hash");
  const license = JSON.parse(memory.get(`licenses/${sha256(key)}.json`)!.body);
  assert.deepEqual(Object.keys(license).sort(), ["created", "devices", "key"]);
});

test("LICENSE_SECRET keys the handles; production refuses to run without it", async (t) => {
  t.after(() => {
    delete process.env.LICENSE_SECRET;
    delete process.env.VERCEL_ENV;
    delete process.env.BLOB_STORE_ID;
  });
  const key = await mint();
  await activateAll(key, ["a", "b"]);
  const other = async () =>
    (await call("devices", { key, deviceId: mac("a").id })).body.devices[1].id;
  const devHandle = await other();
  process.env.LICENSE_SECRET = "test-secret";
  assert.equal(
    await other(),
    hmac("test-secret", `${key}:${mac("b").id}`)
      .toString("base64url")
      .slice(0, 22),
    "base64url(HMAC-SHA256(secret, key:id)), 22 characters",
  );
  assert.notEqual(devHandle, await other());

  delete process.env.LICENSE_SECRET;
  process.env.VERCEL_ENV = "production";
  // A store "configured": the secret is checked first, so no Blob call is made.
  process.env.BLOB_STORE_ID = "store_test";
  for (const action of [
    "demo",
    "activate",
    "devices",
    "deactivate",
    "recover",
  ]) {
    const { status, body } = await call(action, {});
    assert.equal(status, 503, action);
    assert.equal(
      body.error,
      "The license server isn’t set up yet. Please try again later.",
    );
  }
});

test("throttles answer 503 with Retry-After, never 429: per network address, per key and per Mac", async () => {
  const from = "203.0.113.9";
  for (let i = 0; i < 5; i++)
    assert.equal((await call("demo", {}, from)).status, 201);
  const capped = await call("demo", {}, from);
  assert.equal(capped.status, 503);
  assert.ok(Number(capped.headers.get("retry-after")) > 0);
  assert.equal(
    (await call("demo", {})).status,
    201,
    "another address still gets one",
  );

  // The Mac app's routes: 120 calls an hour from one address (the demo key has no per-key cap)...
  const office = "203.0.113.10";
  const demoKey = "ISOLA-DEMO-7Q4K-2M9X";
  for (let i = 0; i < 120; i++)
    assert.equal(
      (await call("devices", { key: demoKey, deviceId: "x" }, office)).status,
      200,
    );
  const busy = await call("devices", { key: demoKey, deviceId: "x" }, office);
  assert.equal(busy.status, 503);
  assert.ok(Number(busy.headers.get("retry-after")) > 0);
  assert.deepEqual(Object.keys(busy.body), ["error"]);

  // ...60 an hour for one key, from anywhere, for callers that aren't on it...
  const key = await mint();
  await activateAll(key, ["a"]); // not on the key yet: this one counts for the key
  for (let i = 1; i < 60; i++)
    assert.equal(
      (await call("devices", { key, deviceId: `stranger-${i}` })).status,
      403,
    );
  const newcomer = await call("activate", { key, device: mac("b") });
  assert.equal(newcomer.status, 503);
  assert.ok(Number(newcomer.headers.get("retry-after")) > 0);

  // ...and 60 an hour for each Mac on it, which nobody else uses up.
  for (let i = 0; i < 60; i++)
    assert.equal(
      (await call("devices", { key, deviceId: mac("a").id })).status,
      200,
    );
  for (const action of ["devices", "activate", "deactivate"]) {
    const { status, headers, body } = await call(action, {
      key,
      deviceId: mac("a").id,
      target: mac("a").id,
      device: mac("a"),
    });
    assert.equal(status, 503, action);
    assert.ok(Number(headers.get("retry-after")) > 0);
    assert.deepEqual(body, {
      error: "Too many requests. Please try again later.",
    });
  }
});

test("an intruder with the key can't use up the first Mac's allowance and stay", async () => {
  const key = await mint();
  await activateAll(key, ["owner", "intruder"]);
  // The intruder hammers the key as itself and under made-up ids, from everywhere...
  for (let i = 0; i < 70; i++) {
    await call("devices", { key, deviceId: mac("intruder").id });
    await call("devices", { key, deviceId: `made-up-${i}` });
  }
  for (const deviceId of [mac("intruder").id, "made-up"])
    assert.equal((await call("devices", { key, deviceId })).status, 503);
  // ...and the first Mac still gets through, and removes it.
  const listed = await call("devices", { key, deviceId: mac("owner").id });
  assert.equal(listed.status, 200);
  const removed = await call("deactivate", {
    key,
    deviceId: mac("owner").id,
    target: listed.body.devices[1].id,
  });
  assert.equal(removed.status, 200);
  assert.deepEqual(ids(removed.body), [mac("owner").id]);
});

test("every POST must be JSON, so a form on another site can't drive the API", async () => {
  const post = (headers: Record<string, string> = {}, method = "POST") =>
    api.fetch(
      new Request("http://localhost/api/license/demo", {
        method,
        headers: { "x-real-ip": `192.0.2.${++address % 250}`, ...headers },
        body: method === "POST" ? "{}" : undefined,
      }),
    );
  for (const type of [
    undefined, // fetch's default for a string body: text/plain
    "text/plain",
    "application/x-www-form-urlencoded",
    "multipart/form-data; boundary=x",
    "application/jsonp",
  ]) {
    const response = await post(type ? { "content-type": type } : {});
    assert.equal(response.status, 415, String(type));
    assert.equal(response.headers.get("access-control-allow-origin"), null);
  }
  assert.equal(
    (await post({ "content-type": "Application/JSON; charset=utf-8" })).status,
    201,
  );
  const preflight = await post({}, "OPTIONS");
  assert.equal(preflight.status, 405, "a CORS preflight gets nothing");
  assert.equal(preflight.headers.get("access-control-allow-origin"), null);
});

test("text must be well-formed and at most 1000 UTF-16 units; long names are cut by code point", async () => {
  const key = await mint();
  for (const device of [
    { ...mac("a"), name: "Mac \ud800" },
    { ...mac("a"), model: "\udfffMac16,1" },
    { ...mac("a"), id: "a-\ud83d" },
  ])
    assert.equal((await call("activate", { key, device })).status, 400);
  assert.equal(
    (await call("devices", { key, deviceId: "\ud800" })).status,
    400,
  );
  for (const device of [
    { ...mac("a"), name: "x".repeat(1001) },
    { ...mac("a"), model: "🍎".repeat(501) }, // 1002 UTF-16 units
  ]) {
    const refused = await call("activate", { key, device });
    assert.equal(refused.status, 400);
    assert.match(refused.body.error, /is too long/);
  }
  assert.equal(
    (await call("recover", { email: `${"a".repeat(990)}@example.com` })).status,
    400,
  );
  const long = await call("activate", {
    key,
    device: { ...mac("a"), name: "🍎".repeat(500) }, // 1000 units: cut, not refused
  });
  assert.equal(long.status, 200);
  assert.equal(long.body.devices[0].name, "🍎".repeat(100));
});

test("a Resend call that hangs is aborted at the same deadline as Blob calls", async (t) => {
  await mint("slow@example.com");
  const aborts: Error[] = [];
  mailbox(
    t,
    (init) =>
      new Promise((_, reject) =>
        init?.signal?.addEventListener("abort", () => {
          aborts.push(init.signal?.reason);
          reject(init.signal?.reason);
        }),
      ),
  );
  // Also swallows the warning that mock timers are experimental.
  const logged = t.mock.method(console, "error", () => {});
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const asked = await call("recover", { email: "slow@example.com" });
  assert.equal(asked.status, 202);
  await new Promise(setImmediate);
  assert.equal(aborts.length, 0, "still waiting");
  t.mock.timers.tick(8_000);
  await new Promise(setImmediate);
  assert.equal(aborts[0]?.name, "AbortError");
  const failures = logged.mock.calls.filter(
    (c) => c.arguments[0] === "license recovery failed:",
  );
  assert.equal(failures.length, 1, "logged, the reply long gone");
});

test("no page can be framed by another site (vercel.json)", async () => {
  const config = JSON.parse(
    await readFile(new URL("../../vercel.json", import.meta.url), "utf8"),
  ) as {
    headers: { source: string; headers: { key: string; value: string }[] }[];
  };
  const rule = config.headers.find((r) =>
    r.headers.some((h) => h.key === "X-Frame-Options"),
  )!;
  assert.deepEqual(
    Object.fromEntries(rule.headers.map((h) => [h.key, h.value])),
    {
      "X-Frame-Options": "DENY",
      "Content-Security-Policy": "frame-ancestors 'none'",
    },
    "frame-ancestors only: a full CSP would break the pages' inline styles",
  );
  const pages = new RegExp(`^${rule.source}$`);
  for (const path of ["/", "/faqs", "/privacy", "/recover", "/purchased/demo"])
    assert.match(path, pages);
  for (const path of ["/assets/index.js", "/fonts/nunito-digits.woff2"])
    assert.doesNotMatch(path, pages);
});

test("a Blob call that hangs is aborted at its deadline, with an error the SDK won't retry", async () => {
  let reason: unknown;
  const hung = withDeadline(
    (signal) =>
      new Promise((_, reject) =>
        signal.addEventListener("abort", () => {
          reason = signal.reason;
          reject(signal.reason);
        }),
      ),
    20,
  );
  await assert.rejects(hung, {
    status: 503,
    message: "The license server is busy. Please try again in a moment.",
  });
  assert.equal((reason as Error).name, "AbortError");
  assert.equal(await withDeadline(async () => "done", 20), "done");
});

test("a write that fails surfaces at once, and endless races end in a 503", async (t) => {
  const key = await mint();
  t.mock.method(console, "error", () => {});
  let writes = 0;
  const set = t.mock.method(memory, "set", () => {
    writes++;
    throw new Error("disk full");
  });
  const failed = await call("activate", { key, device: mac("a") });
  assert.equal(failed.status, 500);
  assert.deepEqual(Object.keys(failed.body), ["error"]);
  assert.equal(writes, 1, "not retried");
  set.mock.restore();

  // Someone else writes between every read and write: 5 tries, then the caller hears about it.
  const realGet = memory.get.bind(memory);
  let n = 0;
  t.mock.method(memory, "get", (path: string) => {
    const hit = realGet(path);
    return hit && { ...hit, etag: `moved-${++n}` };
  });
  const raced = await call("activate", { key, device: mac("a") });
  assert.equal(raced.status, 503);
  assert.equal(
    raced.body.error,
    "The license server is busy. Please try again in a moment.",
  );
});

test("bad requests get a plain 4xx and no internals", async () => {
  const raw = (path: string, init?: RequestInit) =>
    api.fetch(
      new Request(`http://localhost${path}`, {
        ...init,
        headers: { "content-type": "application/json", ...init?.headers },
      }),
    );
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
    (await call("activate", { key: "ISOLA-NOPE", device: mac("a") })).status,
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
        device: { ...mac("a"), id: "x".repeat(101) },
      })
    ).status,
    400,
  );
  assert.equal(
    (await call("activate", { key: "ISOLA-W7UD-A389-NXLG", device: mac("a") }))
      .status,
    404,
  );
  assert.equal(
    (await call("deactivate", { key: "ISOLA-W7UD-A389-NXLG", deviceId: "a" }))
      .status,
    400,
    "no target",
  );
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
  process.env.VERCEL_ENV = "preview";
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
