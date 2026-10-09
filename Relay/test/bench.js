// What one Gmail notification costs the relay: `bun Relay/test/bench.js [path to worker.js]` (default: ../worker.js).
// Counts are exact. Times are a simulation: every outside call is given a fixed made-up delay (below), so they show
// how many round trips sit in a row before the phone hears, not what Cloudflare would measure.
import { resolve } from "node:path";
import { DEVICE_A, DEVICE_B, DEVICE_C, makeWorld, testKey } from "./harness.js";

const path = resolve(process.argv[2] || new URL("../worker.js", import.meta.url).pathname);
const latency = { kv: 8, hub: 2, gmail: 120, google: 150, people: 150, apns: 90 };
const ME = "me@example.com";
const apnsKey = await testKey();

function prepare(world, devices, { token = true, people = true } = {}) {
  const box = world.mailbox(ME);
  box.people = { me: {}, connections: [{ photos: [{ url: "https://photos.test/ada=s100" }], emailAddresses: [{ value: "ada@example.com" }] }], otherContacts: [] };
  world.kv.set(`account:${ME}`, { value: JSON.stringify({ email: ME, refreshToken: `refresh-${ME}`, clientId: "111-abc.apps.test", clientSecret: "", allMail: true, devices: devices.map((token) => ({ token, sandbox: false, avatars: true })), historyId: String(box.historyId), watchExpiry: Date.now() + 5 * 86400000 }) });
  world.kv.set("accounts", { value: JSON.stringify([ME]) });
  world.listen("mac", [ME]);
  return { token, people };
}

/// Fills the caches the way a relay that has been running for a while has them: one earlier mail went through.
async function warmUp(world, options) {
  world.deliver(ME, { id: "warm" });
  await world.pubsub(ME);
  if (!options.token) world.kv.delete(`token:${ME}`);
  if (!options.people) world.kv.delete(`people:${ME}`);
}

const cases = {
  "1 mail, 1 phone, hub awake": { devices: [DEVICE_A], mails: 1 },
  "1 mail, 1 phone, hub asleep": { devices: [DEVICE_A], mails: 1, asleep: true },
  "1 mail, 3 phones, hub awake": { devices: [DEVICE_A, DEVICE_B, DEVICE_C], mails: 1 },
  "5 mails at once, 2 phones, hub awake": { devices: [DEVICE_A, DEVICE_B], mails: 5 },
  "repeat of a notification already handled": { devices: [DEVICE_A], mails: 0 },
  "1 mail, Mac only (no phone)": { devices: [], mails: 1 },
  "first mail of the day (sign-in and contact pictures expired), hub asleep": { devices: [DEVICE_A], mails: 1, asleep: true, token: false, people: false },
};

const rows = [];
for (const [name, setup] of Object.entries(cases)) {
  const samples = [];
  let counts = null;
  for (let run = 0; run < 5; run++) {
    const world = makeWorld({ apnsKey, latency });
    await world.start(path);
    const options = prepare(world, setup.devices, setup);
    await warmUp(world, options);
    // A fresh worker with the store as the earlier mail left it, when the case wants nothing remembered.
    if (setup.asleep) await world.start(path);
    for (const key of Object.keys(world.counts)) world.counts[key] = 0;
    for (const key of Object.keys(world.marks)) delete world.marks[key];
    world.seen.length = 0;
    let at = world.mailbox(ME).historyId;
    for (let i = 0; i < setup.mails; i++) at = world.deliver(ME, { id: `m${i}` });
    const zero = performance.now();
    const timing = await world.pubsub(ME, at);
    const since = (name) => (name in world.marks ? world.marks[name] + world.startedAt - zero : null);
    samples.push({ answered: timing.answered, socket: since("firstSocket"), push: since("firstPush"), finished: timing.finished });
    counts = { ...world.counts, pushes: world.seen.filter((entry) => entry.kind === "apns").length };
  }
  const median = (key) => {
    const values = samples.map((sample) => sample[key]).filter((value) => value !== null).sort((a, b) => a - b);
    return values.length ? Math.round(values[Math.floor(values.length / 2)]) : null;
  };
  rows.push({ case: name, kvRead: counts.kvGet, kvWrite: counts.kvPut + counts.kvDelete, google: counts.fetchGoogleToken, gmail: counts.fetchGmail, people: counts.fetchPeople, apns: counts.fetchApns, hub: counts.hubCalls, sign: counts.sign, "ack ms": median("answered"), "app told ms": median("socket"), "first push ms": median("push"), "all done ms": median("finished") });
}
console.log(`relay: ${path}`);
console.log(`made-up delay per call, ms: ${JSON.stringify(latency)}`);
console.table(rows);
const size = (await Bun.file(path).arrayBuffer()).byteLength;
console.log(`script size: ${size} bytes`);
