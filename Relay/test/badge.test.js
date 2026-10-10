// The number on the app's icon: unread conversations across every inbox the phone holds.
import { expect, test } from "bun:test";
import { DEVICE_A, makeWorld, testKey } from "./harness.js";

const ME = "me@example.com";
const WORK = "me@work.example";
const WORKER = new URL("../worker.js", import.meta.url).pathname;

async function twoAccounts() {
  const world = makeWorld({ apnsKey: await testKey() });
  await world.start(WORKER);
  for (const email of [ME, WORK]) {
    world.kv.set(`account:${email}`, { value: JSON.stringify({ email, refreshToken: `refresh-${email}`, clientId: "111-abc.apps.test", clientSecret: "", allMail: true, devices: [{ token: DEVICE_A, sandbox: false, avatars: true }], historyId: "1000", watchExpiry: Date.now() + 5 * 86400000 }) });
  }
  return world;
}

const badges = (world) => world.seen.filter((entry) => entry.kind === "apns").map((entry) => [entry.headers["apns-collapse-id"], entry.body.aps.badge]);

test("a banner carries the unread total of every account on the phone", async () => {
  const world = await twoAccounts();
  world.deliver(ME, { id: "a" });
  await world.pubsub(ME);
  world.deliver(WORK, { id: "b" });
  await world.pubsub(WORK);
  world.deliver(ME, { id: "c" });
  await world.pubsub(ME);
  expect(badges(world)).toEqual([["a", 1], ["b", 2], ["c", 3]]);
});

test("mail read somewhere else lowers the number and wakes the app to clear its banner, with no banner and no sound", async () => {
  const world = await twoAccounts();
  world.deliver(ME, { id: "a" });
  await world.pubsub(ME);
  world.deliver(WORK, { id: "b" });
  await world.pubsub(WORK);
  world.seen.length = 0;
  const box = world.mailbox(ME);
  box.messages.get("a").labelIds = ["INBOX", "CATEGORY_PERSONAL"];
  box.historyId += 10;
  await world.pubsub(ME);
  const pushes = world.seen.filter((entry) => entry.kind === "apns");
  expect(pushes.map((entry) => entry.body)).toEqual([{ aps: { badge: 1, "content-available": 1 } }]);
  // Gmail saying the same thing again changes nothing.
  box.historyId += 10;
  await world.pubsub(ME);
  expect(world.seen.filter((entry) => entry.kind === "apns").length).toBe(1);
});
