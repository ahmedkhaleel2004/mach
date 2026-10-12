// The Outlook side of the relay, against a made-up Outlook (see harness.js): being told about new mail, the number
// on the icon, bringing snoozed mail back, and the pictures of saved contacts. No network, no real accounts.
import { expect, test } from "bun:test";
import { DEVICE_A, DEVICE_B, makeWorld, testKey } from "./harness.js";

const ME = "me@outlook.example";
const WORKER = new URL("../worker.js", import.meta.url).pathname;
const apnsKey = await testKey();
const PAST = "Snoozed/2020-01-01T09:00:00Z";
const FUTURE = "Snoozed/2999-01-01T09:00:00Z";

/// A relay with one Outlook account signed in on these phones and a Mac listening, with the counters back at zero.
async function signedIn(devices = [DEVICE_A], extra = {}) {
  const world = makeWorld({ apnsKey });
  await world.start(WORKER);
  if (!devices.length) await world.registerOutlook([ME], extra);
  for (const deviceToken of devices) await world.registerOutlook([ME], { deviceToken, ...extra });
  world.listen("mac", [ME]);
  quiet(world);
  return world;
}

function quiet(world) {
  for (const key of Object.keys(world.counts)) world.counts[key] = 0;
  world.seen.length = 0;
  world.graphCalls.length = 0;
}

/// Changes the relay's stored record behind its back, then puts the hub to sleep so it reads the store again.
function rewrite(world, change) {
  world.kv.set(`account:${ME}`, { value: JSON.stringify({ ...world.account(ME), ...change }) });
  world.sleepHub();
}

const pushes = (world) => world.seen.filter((entry) => entry.kind === "apns");
const banners = (world) => pushes(world).filter((entry) => entry.body.aps.alert);
const subjects = (world) => banners(world).map((entry) => entry.body.aps.alert.subtitle);
const told = (world) => world.seen.filter((entry) => entry.kind === "socket").length;
const calls = (world, start) => world.graphCalls.filter((call) => call.startsWith(start));
const shortId = async (id) => btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id))))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "").slice(0, 40);

// Being told about new mail.

test("signing in an Outlook account starts a watch and is instant", async () => {
  const world = makeWorld({ apnsKey });
  await world.start(WORKER);
  await world.registerOutlook([ME], { deviceToken: DEVICE_A });
  expect(world.seen.at(-1)).toEqual({ kind: "http", path: "/register", status: 200, body: { ok: true, accounts: [{ email: ME, instant: true }] } });
  const watch = world.watchOf(ME);
  expect(watch.made.resource).toBe("me/mailFolders('inbox')/messages");
  expect(watch.path).toMatch(/^\/outlook\/[\w-]{40}\?email=me%40outlook\.example$/);
  // Outlook keeps that address, so the relay's secret must be nowhere in it.
  expect(JSON.stringify(watch.made)).not.toContain(world.env.RELAY_SECRET);
  const record = world.account(ME);
  expect(record).toMatchObject({ provider: "microsoft", subscription: watch.id, origin: "https://relay.test", devices: [{ token: DEVICE_A, sandbox: false, avatars: true }] });
  expect(record.watchExpiry).toBeGreaterThan(Date.now() + 5 * 86400000);
  expect(JSON.parse(world.kv.get("accounts").value)).toEqual([ME]);
  // Signing in again (every launch does) changes nothing and makes no second watch.
  await world.registerOutlook([ME], { deviceToken: DEVICE_A });
  expect(world.outlook(ME).subscriptions.size).toBe(1);
  expect(world.refused).toEqual([]);
});

test("the address says back the word Outlook asks it to", async () => {
  const world = await signedIn();
  await world.request("POST", `${world.watchOf(ME).path}&validationToken=prove+it`);
  expect(world.seen.at(-1)).toMatchObject({ status: 200, body: "prove it" });
  expect(world.counts.hubCalls).toBe(0);
});

test("a wrong word in the address is refused, whatever else is right", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME, { path: `/outlook/${"x".repeat(40)}?email=${encodeURIComponent(ME)}` });
  expect(world.seen.at(-1)).toMatchObject({ status: 403 });
  await world.outlookSays(ME, { path: `/outlook/${world.env.RELAY_SECRET}?email=${encodeURIComponent(ME)}` });
  expect(world.seen.at(-1)).toMatchObject({ status: 403 });
  // One account's word does not open another's.
  await world.outlookSays(ME, { path: world.watchOf(ME).path.replace("me%40", "you%40") });
  expect(world.seen.at(-1)).toMatchObject({ status: 403 });
  await world.request("POST", `/outlook/${"x".repeat(40)}?email=${encodeURIComponent(ME)}&validationToken=hello`);
  expect(world.seen.at(-1)).toMatchObject({ status: 403 });
  expect(pushes(world)).toEqual([]);
  expect(world.counts.hubCalls).toBe(0);
});

test("a notification without the agreed word is acknowledged and ignored", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME, { clientState: "made-up" });
  expect(world.seen.at(-1)).toMatchObject({ status: 202 });
  expect(world.counts.hubCalls).toBe(0);
  expect(pushes(world)).toEqual([]);
});

test("new mail is pushed, with the app's connection told first", async () => {
  const world = await signedIn([DEVICE_A, DEVICE_B]);
  const id = "AAMk+long/id==";
  world.deliverOutlook(ME, { id, conversation: "conv=1", subject: "Lunch?", preview: "  Are you​ free\n at   noon? " });
  await world.outlookSays(ME);
  expect(world.seen.map((entry) => entry.kind)).toEqual(["socket", "apns", "apns", "http"]);
  expect(world.seen[0]).toEqual({ kind: "socket", to: "mac", email: ME, hasTime: true });
  expect(world.seen.at(-1)).toMatchObject({ status: 202 });
  const [first, second] = pushes(world).sort((a, b) => a.device.localeCompare(b.device));
  expect(first.device).toBe(DEVICE_A);
  expect(second.device).toBe(DEVICE_B);
  expect(first.headers).toEqual({ "apns-topic": "com.ahmedkhaleel.mach.ios", "apns-push-type": "alert", "apns-priority": "10", "apns-collapse-id": await shortId(id) });
  expect(first.body).toEqual({
    aps: { alert: { title: "Ada Lovelace", subtitle: "Lunch?", body: "Are you free at noon?" }, sound: "default", "thread-id": `${ME}/conv=1`, "content-available": 1, "mutable-content": 1, badge: 1 },
    account: ME, thread: "conv=1", senderEmail: "ada@example.com", senderName: "Ada Lovelace", senderPhoto: "", avatars: true,
  });
});

test("a sender with no name is called by the first half of their address", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1", name: "", address: "Billing@Shop.Example" });
  await world.outlookSays(ME);
  expect(banners(world)[0].body).toMatchObject({ senderName: "billing", senderEmail: "billing@shop.example", aps: { alert: { title: "billing" } } });
});

test("a notification naming a watch that is not the account's ends that watch and pushes nothing", async () => {
  const world = await signedIn();
  const stray = "99999999-aaaa-4bbb-8ccc-000000000000";
  world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME, { subscription: stray });
  expect(pushes(world)).toEqual([]);
  expect(world.outlook(ME).ended).toEqual([stray]);
  expect(world.graphCalls).toEqual([`DELETE /subscriptions/${stray}`]);
  // The account's own watch is untouched, and still brings the mail.
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["Hello"]);
});

test("read mail, drafts and mail from yourself are not pushed", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1", subject: "Read elsewhere", read: true });
  world.deliverOutlook(ME, { id: "m2", subject: "A draft", draft: true });
  world.deliverOutlook(ME, { id: "m3", subject: "From me", address: "Me@Outlook.Example" });
  world.deliverOutlook(ME, { id: "m4", subject: "Filed away", folder: "archive" });
  world.deliverOutlook(ME, { id: "m5", subject: "Real" });
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["Real"]);
});

test("with the inbox split, mail Outlook calls other is not pushed; with one inbox it is", async () => {
  const split = await signedIn([DEVICE_A], { allMail: false });
  split.deliverOutlook(ME, { id: "m1", subject: "Sale", classification: "other" });
  split.deliverOutlook(ME, { id: "m2", subject: "From a person" });
  await split.outlookSays(ME);
  expect(subjects(split)).toEqual(["From a person"]);
  const single = await signedIn();
  single.deliverOutlook(ME, { id: "m1", subject: "Sale", classification: "other" });
  single.deliverOutlook(ME, { id: "m2", subject: "From a person" });
  await single.outlookSays(ME);
  expect(subjects(single)).toEqual(["Sale", "From a person"]);
});

test("the same mail is never pushed twice, and later mail still is", async () => {
  const world = await signedIn();
  const first = world.deliverOutlook(ME, { id: "m1", subject: "One" });
  await world.outlookSays(ME);
  expect(world.account(ME).since).toBe(first.receivedDateTime);
  await world.outlookSays(ME);
  await Promise.all([world.outlookSays(ME), world.outlookSays(ME)]);
  expect(subjects(world)).toEqual(["One"]);
  const second = world.deliverOutlook(ME, { id: "m2", subject: "Two" });
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["One", "Two"]);
  expect(world.account(ME).since).toBe(second.receivedDateTime);
});

test("of seven new mails only the newest five are pushed, oldest first", async () => {
  const world = await signedIn();
  for (let i = 1; i <= 7; i++) world.deliverOutlook(ME, { id: `m${i}`, subject: `Number ${i}` });
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["Number 3", "Number 4", "Number 5", "Number 6", "Number 7"]);
});

test("the number on the icon is the unread conversations in the inbox", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1", conversation: "c1" });
  world.deliverOutlook(ME, { id: "m2", conversation: "c1" });
  world.deliverOutlook(ME, { id: "m3", conversation: "c2" });
  await world.outlookSays(ME);
  expect(banners(world).map((entry) => entry.body.aps.badge)).toEqual([2, 2, 2]);
  // Read somewhere else: the number drops, silently, with no banner.
  world.seen.length = 0;
  world.outlook(ME).messages.get("m3").isRead = true;
  await world.outlookSays(ME);
  expect(pushes(world).map((entry) => [entry.headers["apns-collapse-id"], entry.body])).toEqual([["badge", { aps: { badge: 1, "content-available": 1 } }]]);
  // Outlook saying the same again changes nothing.
  await world.outlookSays(ME);
  expect(pushes(world).length).toBe(1);
});

test("a phone Apple says is gone is forgotten", async () => {
  const world = await signedIn([DEVICE_A, DEVICE_B]);
  world.deadDevices.add(DEVICE_B);
  world.deliverOutlook(ME, { id: "m1", subject: "One" });
  await world.outlookSays(ME);
  expect(world.account(ME).devices.map((device) => device.token)).toEqual([DEVICE_A]);
  world.seen.length = 0;
  world.deliverOutlook(ME, { id: "m2", subject: "Two" });
  await world.outlookSays(ME);
  expect(pushes(world).map((entry) => entry.device)).toEqual([DEVICE_A]);
});

test("a Mac only: nothing to push, but the place in the mail moves on", async () => {
  const world = await signedIn([]);
  const mail = world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(1);
  expect(world.account(ME).since).toBe(mail.receivedDateTime);
});

test("a watch close to running out is renewed by the timer, not made again", async () => {
  const world = await signedIn();
  const id = world.watchOf(ME).id;
  rewrite(world, { watchExpiry: Date.now() + 3600000 });
  await world.cron(3);
  expect(calls(world, "PATCH /subscriptions/")).toEqual([`PATCH /subscriptions/${id}`]);
  expect(calls(world, "POST /subscriptions")).toEqual([]);
  expect(world.account(ME).watchExpiry).toBeGreaterThan(Date.now() + 5 * 86400000);
  expect(world.account(ME).subscription).toBe(id);
  // With days still to run it is left alone.
  quiet(world);
  await world.cron(4);
  expect(calls(world, "PATCH /subscriptions/")).toEqual([]);
});

test("a watch Outlook has dropped is made again when the timer tries to renew it", async () => {
  const world = await signedIn();
  const old = world.watchOf(ME).id;
  world.outlook(ME).subscriptions.clear();
  rewrite(world, { watchExpiry: Date.now() + 3600000 });
  await world.cron(3);
  expect(world.watchOf(ME).id).not.toBe(old);
  expect(world.account(ME).subscription).toBe(world.watchOf(ME).id);
});

test("an account whose watch has lapsed is found by the timer instead", async () => {
  const world = await signedIn();
  rewrite(world, { watchExpiry: 0, origin: "" });
  world.outlook(ME).subscriptions.clear();
  world.deliverOutlook(ME, { id: "m1", subject: "Polled" });
  // Without an address for Outlook to reach there is no watch to make, so every minute looks for itself.
  await world.cron(3);
  expect(subjects(world)).toEqual(["Polled"]);
  expect(told(world)).toBe(1);
});

test("signing out ends the watch and forgets the account", async () => {
  const world = await signedIn();
  const id = world.watchOf(ME).id;
  await world.request("POST", "/unregister", { headers: { "x-mach-secret": world.env.RELAY_SECRET }, body: { email: ME } });
  expect(world.outlook(ME).ended).toEqual([id]);
  expect(world.account(ME)).toBe(null);
  expect(JSON.parse(world.kv.get("accounts").value)).toEqual([]);
  expect(world.kv.has(`token:${ME}`)).toBe(false);
  quiet(world);
  await world.cron(3);
  expect(world.graphCalls).toEqual([]);
});

test("an address that moves from Gmail to Outlook and back starts clean each time", async () => {
  const world = makeWorld({ apnsKey });
  await world.start(WORKER);
  await world.register([ME], { deviceToken: DEVICE_A });
  expect(world.account(ME)).toMatchObject({ historyId: "1000", clientId: "111-abc.apps.test" });

  await world.registerOutlook([ME], { deviceToken: DEVICE_A });
  const outlook = world.account(ME);
  expect(outlook).toMatchObject({ provider: "microsoft", clientId: "outlook-client", subscription: world.watchOf(ME).id });
  expect(outlook.historyId).toBeUndefined();
  expect(outlook.devices.length).toBe(1);
  quiet(world);
  world.deliverOutlook(ME, { id: "o1", subject: "On Outlook" });
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["On Outlook"]);
  // A snooze wakes once, so the record also holds what Outlook calls its folders.
  world.deliverOutlook(ME, { id: "o2", folder: "archive", read: true, categories: [PAST] });
  await world.cron(3);
  expect(world.account(ME).folders).toEqual({ inbox: world.FOLDERS.inbox, archive: world.FOLDERS.archive });

  const watch = world.watchOf(ME).id;
  await world.register([ME], { deviceToken: DEVICE_A });
  const gmail = world.account(ME);
  expect(world.outlook(ME).ended).toEqual([watch]);
  for (const key of ["provider", "subscription", "since", "origin", "hook", "folders"]) expect(gmail[key]).toBeUndefined();
  expect(gmail).toMatchObject({ historyId: "1000", clientId: "111-abc.apps.test" });
  expect(gmail.watchExpiry).toBeGreaterThan(Date.now());
  quiet(world);
  world.deliver(ME, { id: "g1", subject: "On Gmail" });
  await world.pubsub(ME);
  await world.cron(3);
  expect(subjects(world)).toEqual(["On Gmail"]);
  expect(world.graphCalls).toEqual([]);
  // Neither company was ever shown the other's sign-in.
  expect(world.refused).toEqual([]);
});

// Snoozed mail.

/// A conversation of two mails snoozed until `category`: both in the archive, the newer one carrying the snooze.
function snooze(world, name, category, extra = {}) {
  world.deliverOutlook(ME, { id: `${name}-old`, conversation: name, subject: "Trip", folder: "archive", read: true, received: "2026-01-01T10:00:00Z" });
  return world.deliverOutlook(ME, { id: `${name}-new`, conversation: name, subject: "Re: Trip", name: "Grace Hopper", address: "grace@example.com", folder: "archive", read: true, received: "2026-01-02T10:00:00Z", categories: ["Travel", category], ...extra });
}

const folderOf = (world, id) => world.outlook(ME).messages.get(id).parentFolderId;

test("a snooze that has come due is brought back, unread, and the phone hears once", async () => {
  const world = await signedIn();
  snooze(world, "conv/1=", PAST);
  world.deliverOutlook(ME, { id: "mine", conversation: "conv/1=", address: ME, folder: "sent", read: true, received: "2026-01-03T10:00:00Z" });
  await world.cron(3);
  const box = world.outlook(ME).messages;
  expect(folderOf(world, "conv/1=-old")).toBe(world.FOLDERS.inbox);
  expect(folderOf(world, "conv/1=-new")).toBe(world.FOLDERS.inbox);
  // Your own reply stays where it was, and it is the newest mail from someone else that turns unread.
  expect(folderOf(world, "mine")).toBe("sent");
  expect(box.get("mine").isRead).toBe(true);
  expect(box.get("conv/1=-old").isRead).toBe(true);
  expect(box.get("conv/1=-new").isRead).toBe(false);
  expect(box.get("conv/1=-new").categories).toEqual(["Travel"]);
  expect(pushes(world).length).toBe(1);
  expect(pushes(world)[0].headers["apns-collapse-id"]).toBe(await shortId("conv/1=-new"));
  expect(pushes(world)[0].body).toEqual({
    aps: { alert: { title: "Grace Hopper", subtitle: "Re: Trip", body: "Back in your inbox." }, sound: "default", "thread-id": `${ME}/conv/1=`, "content-available": 1, "mutable-content": 1 },
    account: ME, thread: "conv/1=", senderEmail: "grace@example.com", senderName: "Grace Hopper", senderPhoto: "", avatars: true,
  });
  expect(told(world)).toBe(1);
  expect(world.account(ME).folders).toEqual({ inbox: world.FOLDERS.inbox, archive: world.FOLDERS.archive });

  // The next minute finds nothing to do: one question, no banner.
  quiet(world);
  await world.cron(4);
  expect(world.graphCalls.length).toBe(1);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(0);
});

test("a snooze not yet due is left alone", async () => {
  const world = await signedIn();
  snooze(world, "c1", FUTURE);
  await world.cron(3);
  expect(folderOf(world, "c1-new")).toBe(world.FOLDERS.archive);
  expect(world.outlook(ME).messages.get("c1-new")).toMatchObject({ isRead: true, categories: ["Travel", FUTURE] });
  expect(world.graphCalls.length).toBe(1);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(0);
});

test("with nothing snoozed the relay asks Outlook one thing a minute", async () => {
  const world = await signedIn();
  await world.cron(3);
  expect(world.graphCalls).toEqual(["GET /me/messages?$filter=categories/any()&$select=id,conversationId,categories&$top=100"]);
  // Mail filed under ordinary categories, or under something that only looks like a snooze, costs nothing more.
  world.deliverOutlook(ME, { id: "m1", folder: "archive", read: true, categories: ["Receipts", "Snoozed/whenever", "snoozed/2020-01-01T09:00:00Z"] });
  quiet(world);
  await world.cron(4);
  expect(world.counts.fetchGraph).toBe(1);
  expect(world.counts.fetchApns).toBe(0);
  expect(world.account(ME).folders).toBeUndefined();
});

test("the folders are asked for once, not at every snooze", async () => {
  const world = await signedIn();
  snooze(world, "c1", PAST);
  await world.cron(3);
  snooze(world, "c2", PAST);
  await world.cron(4);
  world.sleepHub();
  snooze(world, "c3", PAST);
  await world.cron(5);
  expect(calls(world, "GET /me/mailFolders/").length).toBe(2);
  expect(banners(world).length).toBe(3);
});

test("two snoozes due together both come back, each with its own banner", async () => {
  const world = await signedIn([DEVICE_A, DEVICE_B]);
  snooze(world, "c1", PAST);
  snooze(world, "c2", "Snoozed/2021-06-01T00:00:00Z");
  snooze(world, "c3", FUTURE);
  await world.cron(3);
  expect(pushes(world).map((entry) => entry.body.thread)).toEqual(["c1", "c1", "c2", "c2"]);
  expect(folderOf(world, "c3-new")).toBe(world.FOLDERS.archive);
  expect(told(world)).toBe(1);
});

test("a Mac only: the snooze still comes back and the Mac is told", async () => {
  const world = await signedIn([]);
  snooze(world, "c1", PAST);
  await world.cron(3);
  expect(folderOf(world, "c1-new")).toBe(world.FOLDERS.inbox);
  expect(world.outlook(ME).messages.get("c1-new").categories).toEqual(["Travel"]);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(1);
});

test("an app that wakes the same snooze first leaves the relay nothing to do", async () => {
  const world = await signedIn();
  const newest = snooze(world, "c1", PAST);
  // The app gets there between the relay's first question and its second.
  world.outlook(ME).before = (method, path, box) => {
    if (world.graphCalls.at(-1).includes("conversationId eq")) {
      for (const message of box.messages.values()) message.parentFolderId = world.FOLDERS.inbox;
      Object.assign(newest, { isRead: false, categories: ["Travel"] });
    }
  };
  await world.cron(3);
  expect(calls(world, "POST ")).toEqual([]);
  expect(calls(world, "PATCH ")).toEqual([]);
  expect(pushes(world)).toEqual([]);
});

test("mail an app has already moved back is not moved again, and mail that has gone is not an error", async () => {
  const world = await signedIn();
  snooze(world, "c1", PAST);
  world.outlook(ME).messages.get("c1-old").parentFolderId = world.FOLDERS.inbox;
  world.deliverOutlook(ME, { id: "c1-deleted", conversation: "c1", folder: "archive", read: true, received: "2026-01-01T09:00:00Z" });
  world.outlook(ME).gone.add("c1-deleted");
  await world.cron(3);
  expect(calls(world, "POST ").sort()).toEqual(["POST /me/messages/c1-deleted/move", "POST /me/messages/c1-new/move"]);
  expect(world.outlook(ME).messages.get("c1-new")).toMatchObject({ isRead: false, categories: ["Travel"], parentFolderId: world.FOLDERS.inbox });
  expect(banners(world).length).toBe(1);
});

test("a snooze whose own mail has gone is finished with, without a banner", async () => {
  const world = await signedIn();
  snooze(world, "c1", PAST);
  world.outlook(ME).gone.add("c1-new");
  await world.cron(3);
  expect(folderOf(world, "c1-old")).toBe(world.FOLDERS.inbox);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(1);
});

test("a snooze that cannot be taken off is not announced, and is finished the next minute", async () => {
  const world = await signedIn();
  snooze(world, "c1", PAST);
  world.outlook(ME).failPatches = 1;
  await world.cron(3);
  expect(folderOf(world, "c1-new")).toBe(world.FOLDERS.inbox);
  expect(world.outlook(ME).messages.get("c1-new").categories).toEqual(["Travel", PAST]);
  expect(pushes(world)).toEqual([]);
  expect(told(world)).toBe(0);
  quiet(world);
  await world.cron(4);
  expect(calls(world, "POST ")).toEqual([]);
  expect(world.outlook(ME).messages.get("c1-new")).toMatchObject({ isRead: false, categories: ["Travel"] });
  expect(banners(world).length).toBe(1);
  expect(told(world)).toBe(1);
  await world.cron(5);
  expect(banners(world).length).toBe(1);
});

test("the snooze sits on an older mail: it is taken off there, and the newest mail turns unread", async () => {
  const world = await signedIn();
  snooze(world, "c1", PAST);
  world.deliverOutlook(ME, { id: "c1-newer", conversation: "c1", subject: "Re: Re: Trip", folder: "archive", read: true, received: "2026-01-04T10:00:00Z" });
  await world.cron(3);
  const box = world.outlook(ME).messages;
  expect(box.get("c1-new")).toMatchObject({ isRead: true, categories: ["Travel"] });
  expect(box.get("c1-newer")).toMatchObject({ isRead: false, parentFolderId: world.FOLDERS.inbox });
  expect(banners(world).map((entry) => entry.body.aps.alert.subtitle)).toEqual(["Re: Re: Trip"]);
});

// Pictures of saved contacts.

const PICTURE = new Uint8Array([255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 255, 217]);

function withContacts(world) {
  const box = world.outlook(ME);
  box.contacts = [
    { id: "contact/1+a==", displayName: "Ada", emailAddresses: [{ address: "Ada@Example.com", name: "Ada" }, { address: "ada@work.example", name: "Ada" }] },
    { id: "contact-2", displayName: "No picture", emailAddresses: [{ address: "plain@example.com" }] },
    { id: "contact-3", displayName: "No address", emailAddresses: [] },
  ];
  box.photos.set("contact/1+a==", PICTURE);
}

test("mail from a saved contact carries an address for their picture, and that address serves it", async () => {
  const world = await signedIn();
  withContacts(world);
  world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME);
  const address = banners(world)[0].body.senderPhoto;
  expect(address).toMatch(/^https:\/\/relay\.test\/photo\/[\w-]{40}\?email=me%40outlook\.example&id=contact%2F1%2Ba%3D%3D$/);
  expect(address).not.toContain(world.env.RELAY_SECRET);
  const picture = await world.open("GET", address.replace("https://relay.test", ""));
  expect(picture.status).toBe(200);
  expect(picture.headers.get("content-type")).toBe("image/jpeg");
  expect(picture.headers.get("cache-control")).toBe("private, max-age=86400");
  expect([...picture.bytes]).toEqual([...PICTURE]);
  // Nothing of the picture is kept: the store holds only which contact each address is.
  expect([...world.kv.keys()].sort()).toEqual([`account:${ME}`, "accounts", `contacts:${ME}`, `token:${ME}`]);
  expect(JSON.parse(world.kv.get(`contacts:${ME}`).value)).toEqual({ "ada@example.com": "contact/1+a==", "ada@work.example": "contact/1+a==", "plain@example.com": "contact-2" });
});

test("the contacts are read once for a run of mail, and a woken snooze shows the picture too", async () => {
  const world = await signedIn();
  withContacts(world);
  world.deliverOutlook(ME, { id: "m1" });
  world.deliverOutlook(ME, { id: "m2", address: "ADA@work.example" });
  await world.outlookSays(ME);
  world.deliverOutlook(ME, { id: "m3" });
  await world.outlookSays(ME);
  snooze(world, "c1", PAST, { address: "ada@example.com" });
  await world.cron(3);
  expect(calls(world, "GET /me/contacts").length).toBe(1);
  const addresses = banners(world).map((entry) => entry.body.senderPhoto);
  expect(addresses.length).toBe(4);
  expect(new Set(addresses).size).toBe(1);
  expect(addresses[0]).toContain("/photo/");
});

test("a long list of contacts is read page by page", async () => {
  const world = await signedIn();
  withContacts(world);
  world.outlook(ME).pageSize = 1;
  world.deliverOutlook(ME, { id: "m1", address: "plain@example.com" });
  await world.outlookSays(ME);
  expect(calls(world, "GET /me/contacts").length).toBe(3);
  expect(banners(world)[0].body.senderPhoto).toContain("id=contact-2");
});

test("mail from someone who is not a saved contact carries no picture address", async () => {
  const world = await signedIn();
  withContacts(world);
  world.deliverOutlook(ME, { id: "m1", name: "Stranger", address: "stranger@example.com" });
  await world.outlookSays(ME);
  expect(banners(world)[0].body.senderPhoto).toBe("");
});

test("a wrong word opens no picture, and one picture's word opens no other", async () => {
  const world = await signedIn();
  withContacts(world);
  world.outlook(ME).photos.set("contact-2", PICTURE);
  world.deliverOutlook(ME, { id: "m1" });
  await world.outlookSays(ME);
  const path = banners(world)[0].body.senderPhoto.replace("https://relay.test", "");
  const word = path.match(/^\/photo\/([\w-]+)/)[1];
  quiet(world);
  for (const wrong of [
    path.replace(word, "x".repeat(40)),
    path.replace(word, world.env.RELAY_SECRET),
    path.replace("id=contact%2F1%2Ba%3D%3D", "id=contact-2"),
    path.replace("me%40", "you%40"),
    `/photo/${word}`,
    `/photo/${word}?email=${encodeURIComponent(ME)}`,
    `/photo/${world.watchOf(ME).path.split("/")[2].split("?")[0]}?email=${encodeURIComponent(ME)}&id=contact-2`,
  ]) {
    const answer = await world.open("GET", wrong);
    expect(answer.status).toBe(403);
    expect(answer.bytes.length).toBeLessThan(40);
  }
  // Nothing was asked of Outlook or the store for any of them.
  expect(world.counts).toMatchObject({ fetchGraph: 0, kvGet: 0 });
});

test("a contact with no picture, or an account that has gone, answers 404", async () => {
  const world = await signedIn();
  withContacts(world);
  world.deliverOutlook(ME, { id: "m1", address: "plain@example.com" });
  world.deliverOutlook(ME, { id: "m2" });
  await world.outlookSays(ME);
  const [plain, ada] = banners(world).map((entry) => entry.body.senderPhoto.replace("https://relay.test", ""));
  expect((await world.open("GET", plain)).status).toBe(404);
  expect((await world.open("GET", ada)).status).toBe(200);
  await world.request("POST", "/unregister", { headers: { "x-mach-secret": world.env.RELAY_SECRET }, body: { email: ME } });
  expect((await world.open("GET", ada)).status).toBe(404);
});

test("an account signed in before contacts were asked for still pushes, with no picture", async () => {
  const world = await signedIn();
  world.deliverOutlook(ME, { id: "m1", subject: "One" });
  await world.outlookSays(ME);
  world.deliverOutlook(ME, { id: "m2", subject: "Two" });
  await world.outlookSays(ME);
  expect(subjects(world)).toEqual(["One", "Two"]);
  expect(banners(world).map((entry) => entry.body.senderPhoto)).toEqual(["", ""]);
  // Outlook said no once; it is not asked again for every mail.
  expect(calls(world, "GET /me/contacts").length).toBe(1);
  expect(JSON.parse(world.kv.get(`contacts:${ME}`).value)).toEqual({});
});
