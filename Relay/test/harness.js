// A made-up world for the relay to run in: Gmail, Google sign-in, Apple push, the key-value store and the hub
// are all stand-ins that live in this process. Nothing here touches the network, and no real account, token or
// device appears anywhere.
//
// Everything the relay does that the outside can see is written to `world.seen` (Apple pushes, messages to open
// app connections, HTTP answers), and everything it costs is counted in `world.counts`.

const WEEK = 7 * 86400000;

/// One page of a P-256 private key, generated for these tests only. It signs nothing real.
export async function testKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const text = btoa(String.fromCharCode(...der));
  return `-----BEGIN PRIVATE KEY-----\n${text.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`;
}

const sleep = (ms) => (ms > 0 ? new Promise((resolve) => setTimeout(resolve, ms)) : Promise.resolve());

/// `latency` (milliseconds per kind of call) is zero for the behaviour tests and set by the benchmark.
export function makeWorld({ apnsKey, latency = {} } = {}) {
  const wait = (kind) => sleep(latency[kind] || 0);
  const counts = { kvGet: 0, kvPut: 0, kvDelete: 0, fetchGoogleToken: 0, fetchGmail: 0, fetchPeople: 0, fetchApns: 0, hubCalls: 0, sign: 0, importKey: 0 };
  const seen = [];
  const started = performance.now();
  const marks = {};
  const mark = (name) => {
    if (!(name in marks)) marks[name] = performance.now() - started;
  };

  // The key-value store.
  const kv = new Map();
  const STORE = {
    async get(key, type) {
      counts.kvGet++;
      await wait("kv");
      const entry = kv.get(key);
      if (entry === undefined) return null;
      return type === "json" ? JSON.parse(entry.value) : entry.value;
    },
    async getWithMetadata(key, type) {
      counts.kvGet++;
      await wait("kv");
      const entry = kv.get(key);
      if (entry === undefined) return { value: null, metadata: null };
      return { value: type === "json" ? JSON.parse(entry.value) : entry.value, metadata: entry.metadata ?? null };
    },
    async put(key, value, options = {}) {
      counts.kvPut++;
      await wait("kv");
      kv.set(key, { value: String(value), metadata: options.metadata ?? null });
    },
    async delete(key) {
      counts.kvDelete++;
      await wait("kv");
      kv.delete(key);
    },
  };

  // Gmail's side: what each mailbox holds.
  const mailboxes = new Map();
  const mailbox = (email) => {
    if (!mailboxes.has(email)) mailboxes.set(email, { historyId: 1000, history: [], messages: new Map(), labels: [], threads: new Map(), people: null, historyGone: false });
    return mailboxes.get(email);
  };
  const tokens = new Map(); // access token -> email
  let tokenSerial = 0;
  const deadDevices = new Set();

  const answer = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

  async function fakeFetch(input, init = {}) {
    const url = new URL(typeof input === "string" ? input : input.url);
    const headers = new Headers(init.headers || {});
    if (url.host === "oauth2.googleapis.com") {
      counts.fetchGoogleToken++;
      await wait("google");
      const form = new URLSearchParams(String(init.body));
      const email = form.get("refresh_token").replace(/^refresh-/, "");
      const token = `access-${++tokenSerial}`;
      tokens.set(token, email);
      return answer({ access_token: token, expires_in: 3599 });
    }
    const bearer = (headers.get("authorization") || "").replace(/^Bearer /, "");
    if (url.host === "gmail.googleapis.com") {
      counts.fetchGmail++;
      await wait("gmail");
      const email = tokens.get(bearer);
      if (!email) return answer({ error: { message: "bad token" } }, 401);
      const box = mailbox(email);
      const path = url.pathname.replace("/gmail/v1/users/me", "");
      if (path === "/profile") return answer({ emailAddress: email, historyId: String(box.historyId) });
      if (path === "/watch") return answer({ historyId: String(box.historyId), expiration: String(Date.now() + WEEK) });
      if (path === "/stop") return answer({});
      if (path === "/history") {
        if (box.historyGone) {
          box.historyGone = false;
          return answer({ error: { message: "gone" } }, 404);
        }
        const from = Number(url.searchParams.get("startHistoryId"));
        const records = box.history.filter((record) => record.id > from);
        return answer({ history: records.map((record) => ({ id: String(record.id), messagesAdded: record.added.map((message) => ({ message })) })), historyId: String(box.historyId) });
      }
      if (path.startsWith("/messages/")) {
        const message = box.messages.get(path.slice(10));
        return message ? answer(message) : answer({ error: { message: "not found" } }, 404);
      }
      if (path === "/labels" && (init.method || "GET") === "GET") return answer({ labels: box.labels });
      if (path.startsWith("/labels/") && init.method === "DELETE") {
        box.labels = box.labels.filter((label) => label.id !== path.slice(8));
        return new Response(null, { status: 204 });
      }
      if (path === "/threads") {
        const label = url.searchParams.get("labelIds");
        const max = Number(url.searchParams.get("maxResults") || 100);
        return answer({ threads: [...box.threads.values()].filter((thread) => thread.labelIds.includes(label)).slice(0, max).map((thread) => ({ id: thread.id })) });
      }
      const modify = path.match(/^\/threads\/([^/]+)\/modify$/);
      if (modify) {
        const thread = box.threads.get(modify[1]);
        const change = JSON.parse(init.body);
        thread.labelIds = thread.labelIds.filter((label) => !(change.removeLabelIds || []).includes(label)).concat(change.addLabelIds || []);
        return answer({ id: thread.id });
      }
      const thread = path.match(/^\/threads\/([^/]+)$/);
      if (thread) return answer({ id: thread[1], messages: box.threads.get(thread[1]).messages });
      return answer({ error: { message: `no stand-in for ${path}` } }, 500);
    }
    if (url.host === "people.googleapis.com") {
      counts.fetchPeople++;
      await wait("people");
      const email = tokens.get(bearer);
      const people = email ? mailbox(email).people : null;
      if (!people) return answer({}, 403);
      if (url.pathname.endsWith("/people/me")) return answer(people.me || {});
      if (url.pathname.endsWith("/connections")) return answer({ connections: people.connections || [] });
      if (url.pathname.endsWith("/otherContacts")) return answer({ otherContacts: people.otherContacts || [] });
      return answer({}, 404);
    }
    if (url.host.endsWith("push.apple.com")) {
      counts.fetchApns++;
      mark("firstPush");
      const device = url.pathname.split("/").pop();
      const authorization = headers.get("authorization") || "";
      // The signed token changes every run; what matters is that it is there and has the right shape.
      const shape = /^bearer [\w-]+\.[\w-]+\.[\w-]+$/.test(authorization) ? "bearer <jwt>" : authorization;
      const kept = {};
      for (const name of ["apns-topic", "apns-push-type", "apns-priority", "apns-collapse-id"]) kept[name] = headers.get(name);
      seen.push({ kind: "apns", host: url.host, device, authorization: shape, headers: kept, body: JSON.parse(init.body) });
      await wait("apns");
      if (deadDevices.has(device)) return answer({ reason: "Unregistered" }, 410);
      return new Response(null, { status: 200 });
    }
    throw new Error(`the relay called ${url.host}, which has no stand-in`);
  }

  // The hub: one object, as on Cloudflare. Open app connections are plain objects that record what they are sent.
  const sockets = [];
  const durable = new Map();
  const state = {
    getWebSockets(tag) {
      return sockets.filter((socket) => socket.tags.includes(tag));
    },
    acceptWebSocket(socket, tags) {
      socket.tags = tags;
      sockets.push(socket);
    },
    waitUntil() {},
    storage: {
      async get(key) {
        return durable.get(key);
      },
      async put(key, value) {
        durable.set(key, value);
      },
      async delete(key) {
        durable.delete(key);
      },
    },
  };
  function listen(name, emails) {
    sockets.push({
      tags: emails,
      send(text) {
        mark("firstSocket");
        const message = JSON.parse(text);
        seen.push({ kind: "socket", to: name, email: message.email, hasTime: typeof message.at === "number" });
      },
    });
  }

  const env = {
    STORE,
    RELAY_SECRET: "test-secret",
    APNS_KEY: apnsKey,
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAMID1234",
    BUNDLE_ID: "com.ahmedkhaleel.mach.ios",
    TOPICS: JSON.stringify({ 111: "projects/test/topics/mach" }),
  };

  let module = null;
  let hubObject = null;
  env.HUB = {
    idFromName: (name) => name,
    get() {
      return {
        async fetch(input, init) {
          counts.hubCalls++;
          await wait("hub");
          if (!hubObject) hubObject = new module.Hub(state, env);
          return hubObject.fetch(input instanceof Request ? input : new Request(input, init));
        },
      };
    },
  };

  const world = { counts, seen, kv, env, mailbox, deadDevices, listen, marks, startedAt: started };

  /// Loads the relay's code afresh, the way a newly started worker would: nothing remembered from before.
  world.start = async (path) => {
    module = await import(`${path}?fresh=${Math.random()}`);
    hubObject = null;
  };
  /// The hub is put to sleep between events when nothing is happening; this is that.
  world.sleepHub = () => {
    hubObject = null;
  };

  /// Sends one HTTP request to the relay and waits for everything it started in the background.
  world.request = async (method, path, { body, headers = {} } = {}) => {
    const pending = [];
    const ctx = { waitUntil: (promise) => pending.push(promise) };
    const realFetch = globalThis.fetch;
    const realSign = crypto.subtle.sign;
    const realImport = crypto.subtle.importKey;
    globalThis.fetch = fakeFetch;
    crypto.subtle.sign = function (...args) {
      counts.sign++;
      return realSign.apply(crypto.subtle, args);
    };
    crypto.subtle.importKey = function (...args) {
      counts.importKey++;
      return realImport.apply(crypto.subtle, args);
    };
    try {
      const request = new Request(`https://relay.test${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
      const begun = performance.now();
      const response = await module.default.fetch(request, env, ctx);
      const answered = performance.now() - begun;
      const text = await response.text();
      await Promise.all(pending);
      seen.push({ kind: "http", path: path.replace(env.RELAY_SECRET, "<secret>"), status: response.status, body: text.startsWith("{") ? JSON.parse(text) : text || null });
      return { status: response.status, answered, finished: performance.now() - begun };
    } finally {
      globalThis.fetch = realFetch;
      crypto.subtle.sign = realSign;
      crypto.subtle.importKey = realImport;
    }
  };

  /// What Google Pub/Sub posts when Gmail says a mailbox changed.
  world.pubsub = (email, historyId = world.mailbox(email).historyId) =>
    world.request("POST", `/pubsub/${env.RELAY_SECRET}`, { body: { message: { data: btoa(JSON.stringify({ emailAddress: email, historyId })), messageId: "1" } } });

  /// The once-a-minute timer.
  world.cron = async (minute = 3) => {
    const pending = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = fakeFetch;
    try {
      await module.default.scheduled({ scheduledTime: Date.UTC(2026, 0, 1, 12, minute) }, env, { waitUntil: (promise) => pending.push(promise) });
      await Promise.all(pending);
    } finally {
      globalThis.fetch = realFetch;
    }
  };

  world.register = (accounts, extra = {}) =>
    world.request("POST", "/register", { headers: { "x-mach-secret": env.RELAY_SECRET }, body: { accounts: accounts.map((email) => ({ email, refreshToken: `refresh-${email}`, clientId: "111-abc.apps.test" })), ...extra } });

  /// New mail lands in a made-up mailbox.
  world.deliver = (email, { id, thread = `t-${id}`, from = "Ada Lovelace <ada@example.com>", subject = "Hello", snippet = "A short &amp; friendly note", labels = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"] }) => {
    const box = mailbox(email);
    box.historyId += 10;
    const message = { id, threadId: thread, labelIds: labels, snippet, payload: { headers: [{ name: "From", value: from }, { name: "Subject", value: subject }] } };
    box.messages.set(id, message);
    box.history.push({ id: box.historyId, added: [{ id, threadId: thread, labelIds: labels }] });
    return box.historyId;
  };

  /// The relay's own record of an account, with the parts that differ run to run left out.
  world.record = (email) => {
    const entry = kv.get(`account:${email}`);
    if (!entry) return null;
    const account = JSON.parse(entry.value);
    return { historyId: String(account.historyId), devices: account.devices, allMail: account.allMail, watching: account.watchExpiry > Date.now() };
  };

  return world;
}

export const DEVICE_A = "a".repeat(64);
export const DEVICE_B = "b".repeat(64);
export const DEVICE_C = "c".repeat(64);
