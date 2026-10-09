// What the performance work is for: fewer trips per notification. These hold the counts in place.
import { expect, test } from "bun:test";
import { DEVICE_A, makeWorld, testKey } from "./harness.js";

const ME = "me@example.com";
const WORKER = new URL("../worker.js", import.meta.url).pathname;

/// A relay that has already pushed one mail for a known account, with the counters back at zero.
async function running() {
  const world = makeWorld({ apnsKey: await testKey() });
  await world.start(WORKER);
  world.kv.set(`account:${ME}`, { value: JSON.stringify({ email: ME, refreshToken: `refresh-${ME}`, clientId: "111-abc.apps.test", clientSecret: "", allMail: true, devices: [{ token: DEVICE_A, sandbox: false, avatars: true }], historyId: "1000", watchExpiry: Date.now() + 5 * 86400000 }) });
  world.deliver(ME, { id: "first" });
  await world.pubsub(ME);
  for (const key of Object.keys(world.counts)) world.counts[key] = 0;
  world.seen.length = 0;
  return world;
}

const pushed = (world) => world.seen.filter((entry) => entry.kind === "apns").map((entry) => entry.headers["apns-collapse-id"]);

test("a second mail costs no store reads, one hub call and one store write", async () => {
  const world = await running();
  world.deliver(ME, { id: "second" });
  await world.pubsub(ME);
  expect(world.counts).toMatchObject({ kvGet: 0, kvPut: 1, fetchGmail: 2, fetchApns: 1, hubCalls: 1, sign: 0, fetchGoogleToken: 0 });
  expect(pushed(world)).toEqual(["second"]);
});

test("a repeated notification asks Gmail nothing, and new mail after it is still pushed", async () => {
  const world = await running();
  await world.pubsub(ME);
  await world.pubsub(ME, 5);
  expect(world.counts).toMatchObject({ kvGet: 0, kvPut: 0, fetchGmail: 0, fetchApns: 0 });
  world.deliver(ME, { id: "later" });
  await world.pubsub(ME);
  expect(pushed(world)).toEqual(["later"]);
});

test("a notification with no place in the change log is always looked into", async () => {
  const world = await running();
  world.deliver(ME, { id: "second" });
  await world.request("POST", `/pubsub/${world.env.RELAY_SECRET}`, { body: { message: { data: btoa(JSON.stringify({ emailAddress: ME })) } } });
  expect(pushed(world)).toEqual(["second"]);
});

test("a hub that slept reuses Apple's sign-in token instead of signing a new one", async () => {
  const world = await running();
  await world.start(WORKER);
  world.deliver(ME, { id: "second" });
  await world.pubsub(ME);
  expect(world.counts.sign).toBe(0);
  expect(pushed(world)).toEqual(["second"]);
});

test("a hub that slept reads the store afresh, so a record changed meanwhile is honoured", async () => {
  const world = await running();
  const record = JSON.parse(world.kv.get(`account:${ME}`).value);
  world.kv.set(`account:${ME}`, { value: JSON.stringify({ ...record, devices: [] }) });
  await world.start(WORKER);
  world.deliver(ME, { id: "second" });
  await world.pubsub(ME);
  expect(pushed(world)).toEqual([]);
});

test("a token stored by the relay as it was before is still used", async () => {
  const world = await running();
  world.kv.set(`token:${ME}`, { value: world.kv.get(`token:${ME}`).value, metadata: null });
  await world.start(WORKER);
  world.deliver(ME, { id: "second" });
  await world.pubsub(ME);
  expect(world.counts.fetchGoogleToken).toBe(0);
  expect(pushed(world)).toEqual(["second"]);
});

test("a token Gmail refuses is thrown away and a new one fetched next time", async () => {
  const world = await running();
  world.kv.set(`token:${ME}`, { value: "revoked", metadata: { until: Date.now() + 3000000 } });
  await world.start(WORKER);
  world.deliver(ME, { id: "second" });
  await world.pubsub(ME);
  expect(pushed(world)).toEqual([]);
  await world.pubsub(ME);
  expect(world.counts.fetchGoogleToken).toBe(1);
  expect(pushed(world)).toEqual(["second"]);
});
