// The public relay in a made-up world: the store, Apple and the clock's callers are stand-ins in this process.
import { beforeEach, expect, test } from "bun:test";
import { testKey } from "./harness.js";

const ID = "i".repeat(43);
const SECRET = "s".repeat(43);
const DEVICE = "ab".repeat(32);
let env, kv, pushes, dead, worker, waiting;

beforeEach(async () => {
  kv = new Map();
  pushes = [];
  dead = new Set();
  waiting = [];
  env = {
    STORE: {
      async get(key) { return kv.has(key) ? JSON.parse(kv.get(key).value) : null; },
      async put(key, value, options) { kv.set(key, { value, options }); },
      async delete(key) { kv.delete(key); },
    },
    STORE_KEY: btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))),
    APNS_KEY: await testKey(), APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAM123456", BUNDLE_ID: "com.example.mach",
  };
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input);
    if (!url.host.endsWith("push.apple.com")) throw new Error(`the relay called ${url.host}`);
    const device = url.pathname.split("/").pop();
    pushes.push({ host: url.host, device, headers: init.headers, body: JSON.parse(init.body) });
    return dead.has(device) ? new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }) : new Response(null, { status: 200 });
  };
  // A fresh copy each time, so nothing remembered in memory carries over.
  worker = (await import(`../public.js?${Math.random()}`)).default;
});

const ctx = { waitUntil: (work) => waiting.push(work) };
async function call(path, body, ip = "1.1.1.1") {
  const response = await worker.fetch(new Request(`https://push.example${path}`, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body), headers: { "cf-connecting-ip": ip } }), env, ctx);
  await Promise.all(waiting.splice(0));
  return response;
}
const register = (extra = {}) => call("/v1/register", { id: ID, secret: SECRET, deviceToken: DEVICE, sandbox: false, ...extra });
const mail = (message = "AQMk-message-1", extra = {}) => ({ value: [{ changeType: "created", clientState: SECRET, subscriptionId: "sub-1", resourceData: { id: message }, ...extra }] });

test("a registered phone is pushed the id of new mail and nothing about it", async () => {
  expect((await register()).status).toBe(200);
  expect((await call(`/v1/outlook/${ID}`, mail())).status).toBe(202);
  expect(pushes.length).toBe(1);
  expect(pushes[0].device).toBe(DEVICE);
  expect(pushes[0].host).toBe("api.push.apple.com");
  expect(pushes[0].body.mach).toEqual({ id: ID, message: "AQMk-message-1" });
  expect(pushes[0].body.aps.alert).toEqual({ title: "New mail", body: "Open Mach to read it." });
  expect(pushes[0].body.aps["mutable-content"]).toBe(1);
  expect(pushes[0].headers["apns-collapse-id"].length).toBe(40);
});

test("what is stored names nobody: no id, no secret, no push address in the clear", async () => {
  await register();
  expect(kv.size).toBe(1);
  const [[name, entry]] = [...kv];
  const text = name + entry.value;
  for (const word of [ID, SECRET, DEVICE]) expect(text.includes(word)).toBe(false);
  expect(entry.options.expirationTtl).toBe(15 * 86400);
});

test("Outlook's first call is answered with its own word, only for a registered id", async () => {
  expect((await call(`/v1/outlook/${ID}?validationToken=hello%20there`)).status).toBe(404);
  await register();
  const answer = await call(`/v1/outlook/${ID}?validationToken=hello%20there`);
  expect(answer.status).toBe(200);
  expect(await answer.text()).toBe("hello there");
});

test("a call without the right secret pushes nothing", async () => {
  await register();
  await call(`/v1/outlook/${ID}`, mail("m1", { clientState: "x".repeat(43) }));
  await call(`/v1/outlook/${ID}`, mail("m1", { clientState: undefined }));
  await call(`/v1/outlook/${"z".repeat(43)}`, mail());
  expect(pushes.length).toBe(0);
});

test("only arriving mail is pushed, once per message", async () => {
  await register();
  await call(`/v1/outlook/${ID}`, { value: [mail("m1").value[0], mail("m1").value[0], mail("m2", { changeType: "updated" }).value[0], mail("m3").value[0]] });
  expect(pushes.map((push) => push.body.mach.message)).toEqual(["m1", "m3"]);
});

test("nobody can take over or delete an id without its secret", async () => {
  await register();
  expect((await register({ secret: "x".repeat(43), deviceToken: "cd".repeat(32) })).status).toBe(403);
  expect((await call("/v1/forget", { id: ID, secret: "x".repeat(43) })).status).toBe(403);
  await call(`/v1/outlook/${ID}`, mail());
  expect(pushes[0].device).toBe(DEVICE);
});

test("signing out deletes the record at once", async () => {
  await register();
  expect((await call("/v1/forget", { id: ID, secret: SECRET })).status).toBe(200);
  expect(kv.size).toBe(0);
  expect((await call(`/v1/outlook/${ID}`, mail())).status).toBe(404);
  expect(pushes.length).toBe(0);
});

test("a phone Apple says is gone is forgotten", async () => {
  await register();
  dead.add(DEVICE);
  await call(`/v1/outlook/${ID}`, mail());
  expect(kv.size).toBe(0);
});

test("a new push address replaces the old one; saying the same thing again writes nothing", async () => {
  await register();
  const first = [...kv.values()][0].value;
  await register();
  expect([...kv.values()][0].value).toBe(first);
  await register({ deviceToken: "cd".repeat(32), sandbox: true });
  await call(`/v1/outlook/${ID}`, mail());
  expect(pushes[0].device).toBe("cd".repeat(32));
  expect(pushes[0].host).toBe("api.sandbox.push.apple.com");
});

test("malformed requests are refused", async () => {
  expect((await register({ id: "short" })).status).toBe(400);
  expect((await register({ deviceToken: "not-hex" })).status).toBe(400);
  expect((await call("/v1/register", undefined)).status).toBe(400);
});

test("a flood is cut off: registrations per caller, pushes per mailbox", async () => {
  await register();
  for (let index = 0; index < 40; index++) await call(`/v1/outlook/${ID}`, mail(`m${index}`));
  expect(pushes.length).toBe(30);
  let refused = 0;
  for (let index = 0; index < 70; index++) if ((await register({}, )).status === 429) refused++;
  expect(refused).toBeGreaterThan(0);
  expect((await call("/v1/register", { id: ID, secret: SECRET, deviceToken: DEVICE }, "2.2.2.2")).status).toBe(200);
});
