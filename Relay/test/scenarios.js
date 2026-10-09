// Situations the relay has to handle, each played against a made-up world (see harness.js). `play` returns, for
// every situation, exactly what left the relay: Apple pushes, messages to open app connections, HTTP answers, and
// the account records it ended up holding. golden.json is that output from the relay as it was before any
// performance work; relay.test.js checks today's relay still produces the same thing.

import { DEVICE_A, DEVICE_B, DEVICE_C, makeWorld, testKey } from "./harness.js";

const ME = "me@example.com";
const WORK = "me@work.example";

/// An account that Gmail notifies us about, already known to the relay, with these phones.
function known(world, email, devices, extra = {}) {
  const box = world.mailbox(email);
  world.kv.set(`account:${email}`, {
    value: JSON.stringify({ email, refreshToken: `refresh-${email}`, clientId: "111-abc.apps.test", clientSecret: "", allMail: true, devices, historyId: String(box.historyId), watchExpiry: Date.now() + 5 * 86400000, ...extra }),
  });
  world.kv.set("accounts", { value: JSON.stringify([...new Set([...JSON.parse(world.kv.get("accounts")?.value || "[]"), email])]) });
}

const phone = (token, extra = {}) => ({ token, sandbox: false, avatars: true, ...extra });

export const scenarios = {
  // One new mail from a person; two phones (one with pictures off, one a development build) and a Mac listening.
  async "one new mail, two phones and a Mac"(world) {
    known(world, ME, [phone(DEVICE_A), phone(DEVICE_B, { avatars: false, sandbox: true })]);
    world.mailbox(ME).people = { me: { photos: [{ url: "https://photos.test/me=s100" }], emailAddresses: [{ value: ME }] }, connections: [{ photos: [{ url: "https://photos.test/ada=s100" }], emailAddresses: [{ value: "Ada@Example.com" }] }], otherContacts: [{ photos: [{ url: "https://photos.test/other-ada=s100" }], emailAddresses: [{ value: "ada@example.com" }] }, { photos: [{ default: true, url: "https://photos.test/default" }], emailAddresses: [{ value: "bob@example.com" }] }] };
    world.listen("mac", [ME]);
    world.listen("other-mac", [WORK]);
    world.deliver(ME, { id: "m1", snippet: "Tom &amp; Jerry &#39;quoted&#39; &lt;b&gt;​" });
    await world.pubsub(ME);
  },

  // Gmail often says the same thing several times. Only the first notification may push.
  async "the same notification three times"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    world.listen("mac", [ME]);
    const at = world.deliver(ME, { id: "m1" });
    await world.pubsub(ME, at);
    await world.pubsub(ME, at);
    await world.pubsub(ME, at);
  },

  // The same, but the three arrive on top of each other rather than one after another.
  async "three notifications at once"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    world.listen("mac", [ME]);
    const at = world.deliver(ME, { id: "m1" });
    await Promise.all([world.pubsub(ME, at), world.pubsub(ME, at), world.pubsub(ME, at)]);
  },

  // Several mails before the relay looks: sent mail, mail already read, and mail read by the time it is fetched
  // are all left out; the rest are pushed oldest first.
  async "a burst of mail"(world) {
    known(world, ME, [phone(DEVICE_A), phone(DEVICE_B)]);
    world.deliver(ME, { id: "m1", from: "\"Lovelace, Ada\" <ada@example.com>", subject: "First" });
    world.deliver(ME, { id: "m2", from: "news@shop.example", subject: "Sale", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"] });
    world.deliver(ME, { id: "m3", subject: "Mine", labels: ["INBOX", "UNREAD", "SENT"] });
    world.deliver(ME, { id: "m4", subject: "Read elsewhere", labels: ["INBOX"] });
    world.deliver(ME, { id: "m5", from: "<bare@example.com>", subject: "Read while fetching" });
    world.mailbox(ME).messages.get("m5").labelIds = ["INBOX"];
    world.deliver(ME, { id: "m6", from: "Grace Hopper <grace@example.com>", subject: "Last" });
    await world.pubsub(ME);
  },

  // More than five new mails: only the newest five are pushed.
  async "seven new mails"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    for (let i = 1; i <= 7; i++) world.deliver(ME, { id: `m${i}`, subject: `Number ${i}` });
    await world.pubsub(ME);
  },

  // With the inbox split, promotions and the like get no banner.
  async "split inbox leaves out bulk mail"(world) {
    known(world, ME, [phone(DEVICE_A)], { allMail: false });
    world.deliver(ME, { id: "m1", subject: "Sale", labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"] });
    world.deliver(ME, { id: "m2", subject: "From a person" });
    await world.pubsub(ME);
  },

  // Apple says one phone is gone: it is forgotten, and the next mail goes only to the phones left.
  async "a phone that no longer exists"(world) {
    known(world, ME, [phone(DEVICE_A), phone(DEVICE_B), phone(DEVICE_C)]);
    world.deadDevices.add(DEVICE_B);
    world.deliver(ME, { id: "m1", subject: "One" });
    world.deliver(ME, { id: "m2", subject: "Two" });
    await world.pubsub(ME);
    world.deliver(ME, { id: "m3", subject: "Three" });
    await world.pubsub(ME);
  },

  // A Mac only: nothing to push, but the Mac is told and the place in Gmail's change log moves on.
  async "no phones, only a Mac"(world) {
    known(world, ME, []);
    world.listen("mac", [ME]);
    world.deliver(ME, { id: "m1" });
    await world.pubsub(ME);
  },

  // Two accounts on one phone, mail for each.
  async "two accounts"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    known(world, WORK, [phone(DEVICE_A)]);
    world.listen("mac", [ME, WORK]);
    world.deliver(ME, { id: "m1", subject: "Personal" });
    world.deliver(WORK, { id: "w1", from: "Boss <boss@work.example>", subject: "Work" });
    await Promise.all([world.pubsub(ME), world.pubsub(WORK)]);
  },

  // Mail for an account the relay has never heard of.
  async "an account nobody registered"(world) {
    world.listen("mac", ["stranger@example.com"]);
    await world.pubsub("stranger@example.com");
  },

  // Gmail's change log no longer reaches back to where the relay was: it starts again from now, without pushing.
  async "change log too old"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    world.deliver(ME, { id: "m1" });
    world.mailbox(ME).historyGone = true;
    await world.pubsub(ME);
    world.deliver(ME, { id: "m2", subject: "After the reset" });
    await world.pubsub(ME);
  },

  // A phone signs up, then mail arrives; then the Mac signs up too (no phone token).
  async "register, then mail"(world) {
    await world.register([ME, WORK], { deviceToken: DEVICE_A, sandbox: true, avatars: false, allMail: false });
    await world.register([ME], {});
    world.listen("mac", [ME]);
    world.deliver(ME, { id: "m1", subject: "Welcome" });
    await world.pubsub(ME);
    await world.register([ME, WORK], { deviceToken: DEVICE_A, sandbox: true, avatars: true, allMail: true });
    world.deliver(ME, { id: "m2", subject: "Sale", labels: ["INBOX", "UNREAD", "CATEGORY_UPDATES"] });
    await world.pubsub(ME);
  },

  // An account with no Gmail notifications is found by the once-a-minute timer instead.
  async "found by the timer"(world) {
    known(world, ME, [phone(DEVICE_A)], { clientId: "999-other.apps.test", watchExpiry: 0 });
    world.listen("mac", [ME]);
    await world.cron(3);
    world.deliver(ME, { id: "m1", subject: "Polled" });
    await world.cron(4);
    await world.cron(5);
  },

  // The timer renews Gmail's notifications before they run out, and re-checks watched accounts every ten minutes.
  async "timer renews the watch"(world) {
    known(world, ME, [phone(DEVICE_A)], { watchExpiry: Date.now() + 3600000 });
    world.deliver(ME, { id: "m1", subject: "Missed notification" });
    await world.cron(7);
    await world.cron(10);
  },

  // A snooze comes due while no app is running: the mail comes back and the phone hears about it.
  async "a snooze comes due"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    world.listen("mac", [ME]);
    const box = world.mailbox(ME);
    box.labels = [{ id: "L1", name: "Snoozed/2020-01-01T09:00:00Z" }, { id: "L2", name: "Snoozed/2999-01-01T09:00:00Z" }, { id: "L3", name: "Receipts" }];
    box.threads.set("t9", { id: "t9", labelIds: ["L1"], messages: [{ id: "old", payload: { headers: [{ name: "From", value: "Ada Lovelace <ada@example.com>" }, { name: "Subject", value: "Later" }] } }] });
    await world.cron(3);
  },

  // Signed out on the device: the relay forgets the account; later mail does nothing.
  async "signed out"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    known(world, WORK, [phone(DEVICE_A)]);
    world.deliver(ME, { id: "m1", subject: "Before" });
    await world.pubsub(ME);
    await world.request("POST", "/unregister", { headers: { "x-mach-secret": world.env.RELAY_SECRET }, body: { email: ME } });
    world.deliver(ME, { id: "m2", subject: "After" });
    await world.pubsub(ME);
  },

  // The test button, and the doors that must stay shut.
  async "test push and wrong secrets"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    await world.request("POST", "/test", { headers: { "x-mach-secret": world.env.RELAY_SECRET } });
    await world.request("POST", "/test", { headers: { "x-mach-secret": "wrong" } });
    await world.request("POST", "/pubsub/wrong", { body: {} });
    await world.request("POST", "/register", { headers: { "x-mach-secret": "wrong" }, body: {} });
    await world.request("POST", "/register", { headers: { "x-mach-secret": world.env.RELAY_SECRET }, body: { deviceToken: "not hex", accounts: [] } });
    await world.request("GET", "/");
  },

  // The hub is put to sleep between quiet moments and must carry on correctly when woken.
  async "mail, sleep, mail"(world) {
    known(world, ME, [phone(DEVICE_A)]);
    world.deliver(ME, { id: "m1", subject: "Before the nap" });
    await world.pubsub(ME);
    world.sleepHub();
    world.deliver(ME, { id: "m2", subject: "After the nap" });
    await world.pubsub(ME);
  },
};

export async function play(workerPath) {
  const apnsKey = await testKey();
  const result = {};
  for (const [name, scenario] of Object.entries(scenarios)) {
    const world = makeWorld({ apnsKey });
    await world.start(workerPath);
    await scenario(world);
    // One message goes to all of an account's phones side by side; which phone's push leaves first means nothing.
    // Put each such group in a fixed order (by phone) so only real differences show.
    const seen = world.seen;
    for (let start = 0; start < seen.length; ) {
      let end = start + 1;
      if (seen[start].kind === "apns") {
        while (end < seen.length && seen[end].kind === "apns" && seen[end].headers["apns-collapse-id"] === seen[start].headers["apns-collapse-id"]) end++;
        seen.splice(start, end - start, ...seen.slice(start, end).sort((a, b) => a.device.localeCompare(b.device)));
      }
      start = end;
    }
    result[name] = { seen,records: { [ME]: world.record(ME), [WORK]: world.record(WORK) }, accounts: JSON.parse(world.kv.get("accounts")?.value || "[]") };
  }
  return result;
}
