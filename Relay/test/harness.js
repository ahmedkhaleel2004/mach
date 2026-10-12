// A made-up world for the relay to run in: Gmail, Google sign-in, Outlook, Microsoft sign-in, Apple push, the
// key-value store and the hub are all stand-ins that live in this process. Nothing here touches the network, and no real account, token or
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
  const counts = { kvGet: 0, kvPut: 0, kvDelete: 0, fetchGoogleToken: 0, fetchGmail: 0, fetchPeople: 0, fetchApns: 0, hubCalls: 0, sign: 0, importKey: 0, fetchMicrosoftToken: 0, fetchGraph: 0 };
  const seen = [];
  // Every call the relay makes to Outlook, in order, as "METHOD /path?query" (the query decoded).
  const graphCalls = [];
  // Calls that arrived with a sign-in token from the wrong company. There should never be any.
  const refused = [];
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
  const microsoftTokens = new Map(); // the same, for Outlook; a token from one side is no good on the other

  // Outlook's side: what each mailbox holds. `contacts: null` is a sign-in from before the app asked to see them.
  const outlooks = new Map();
  const outlook = (email) => {
    if (!outlooks.has(email)) outlooks.set(email, { messages: new Map(), subscriptions: new Map(), ended: [], contacts: null, photos: new Map(), pageSize: 500, gone: new Set(), failPatches: 0, serial: 0, before: null });
    return outlooks.get(email);
  };
  const FOLDERS = { inbox: "folder-inbox", archive: "folder-archive" };
  const pick = (message, select) => (select ? Object.fromEntries(select.split(",").filter((field) => field in message).map((field) => [field, message[field]])) : message);

  async function fakeGraph(url, init, bearer) {
    counts.fetchGraph++;
    await wait("graph");
    const method = init.method || "GET";
    const path = decodeURIComponent(url.pathname.replace("/v1.0", ""));
    const query = [...url.searchParams].map(([name, value]) => `${name}=${value}`).join("&");
    graphCalls.push(`${method} ${path}${query ? `?${query}` : ""}`);
    const email = microsoftTokens.get(bearer);
    if (!email) {
      refused.push(`${method} graph ${path}`);
      return answer({ error: { message: "bad token" } }, 401);
    }
    const box = outlook(email);
    if (box.before) await box.before(method, path, box);
    const select = url.searchParams.get("$select");
    const filter = url.searchParams.get("$filter") || "";
    const top = Number(url.searchParams.get("$top") || 10);
    const list = (messages) => answer({ value: messages.slice(0, top).map((message) => pick(message, select)) });
    const body = init.body ? JSON.parse(init.body) : {};

    if (path === "/subscriptions" && method === "POST") {
      const id = `0000${++box.serial}-aaaa-4bbb-8ccc-${email.length.toString(16).padStart(12, "0")}`;
      box.subscriptions.set(id, body);
      return answer({ id, expirationDateTime: body.expirationDateTime }, 201);
    }
    const subscription = path.match(/^\/subscriptions\/([^/]+)$/);
    if (subscription && method === "PATCH") {
      if (!box.subscriptions.has(subscription[1])) return answer({ error: { message: "no such subscription" } }, 404);
      Object.assign(box.subscriptions.get(subscription[1]), body);
      return answer({ id: subscription[1], ...body });
    }
    if (subscription && method === "DELETE") {
      box.ended.push(subscription[1]);
      return new Response(null, { status: box.subscriptions.delete(subscription[1]) ? 204 : 404 });
    }
    const folder = path.match(/^\/me\/mailFolders\/(inbox|archive)$/);
    if (folder) return answer({ id: FOLDERS[folder[1]] });
    if (path === "/me/mailFolders/inbox/messages") {
      const inbox = [...box.messages.values()].filter((message) => message.parentFolderId === FOLDERS.inbox);
      const since = filter.match(/^receivedDateTime gt (\S+)$/);
      if (since) return list(inbox.filter((message) => Date.parse(message.receivedDateTime) > Date.parse(since[1])).sort((a, b) => Date.parse(b.receivedDateTime) - Date.parse(a.receivedDateTime)));
      if (filter === "isRead eq false") return list(inbox.filter((message) => !message.isRead));
      return answer({ error: { message: `no stand-in for the filter ${filter}` } }, 400);
    }
    if (path === "/me/messages") {
      const all = [...box.messages.values()];
      if (filter === "categories/any()") return list(all.filter((message) => message.categories.length));
      const conversation = filter.match(/^conversationId eq '(.*)'$/);
      if (conversation) return list(all.filter((message) => message.conversationId === conversation[1].replace(/''/g, "'")));
      // The real Outlook refuses anything cleverer inside any(), and so does this one.
      return answer({ error: { message: `no stand-in for the filter ${filter}` } }, 400);
    }
    const move = path.match(/^\/me\/messages\/(.+)\/move$/);
    if (move) {
      const message = box.messages.get(move[1]);
      if (!message || box.gone.has(move[1])) return answer({ error: { message: "not found" } }, 404);
      message.parentFolderId = body.destinationId;
      return answer(message, 201);
    }
    const one = path.match(/^\/me\/messages\/(.+)$/);
    if (one && method === "PATCH") {
      const message = box.messages.get(one[1]);
      if (!message || box.gone.has(one[1])) return answer({ error: { message: "not found" } }, 404);
      if (box.failPatches > 0) {
        box.failPatches--;
        return answer({ error: { message: "try later" } }, 503);
      }
      Object.assign(message, body);
      return answer(message);
    }
    if (path === "/me/contacts") {
      if (!box.contacts) return answer({ error: { message: "access denied" } }, 403);
      const skip = Number(url.searchParams.get("$skip") || 0);
      const size = Math.min(top, box.pageSize);
      const page = { value: box.contacts.slice(skip, skip + size).map((contact) => pick(contact, select)) };
      if (skip + size < box.contacts.length) page["@odata.nextLink"] = `https://graph.microsoft.com/v1.0/me/contacts?$select=${select}&$top=${top}&$skip=${skip + size}`;
      return answer(page);
    }
    const photo = path.match(/^\/me\/contacts\/(.+)\/photo\/\$value$/);
    if (photo) {
      const bytes = box.contacts ? box.photos.get(photo[1]) : null;
      return bytes ? new Response(bytes, { status: 200, headers: { "content-type": "image/jpeg" } }) : answer({ error: { message: "no picture" } }, 404);
    }
    return answer({ error: { message: `no stand-in for ${method} ${path}` } }, 500);
  }
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
    if (url.host === "login.microsoftonline.com") {
      counts.fetchMicrosoftToken++;
      await wait("microsoft");
      const form = new URLSearchParams(String(init.body));
      const token = `outlook-access-${++tokenSerial}`;
      microsoftTokens.set(token, form.get("refresh_token").replace(/^refresh-/, ""));
      return answer({ access_token: token, expires_in: 3599 });
    }
    const bearer = (headers.get("authorization") || "").replace(/^Bearer /, "");
    if (url.host === "graph.microsoft.com") return fakeGraph(url, init, bearer);
    if (url.host === "gmail.googleapis.com") {
      counts.fetchGmail++;
      await wait("gmail");
      const email = tokens.get(bearer);
      if (!email && microsoftTokens.has(bearer)) refused.push(`${init.method || "GET"} gmail ${url.pathname}`);
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
      if (path === "/labels/INBOX") {
        const unread = new Set([...box.messages.values()].filter((message) => message.labelIds.includes("INBOX") && message.labelIds.includes("UNREAD")).map((message) => message.threadId));
        return answer({ id: "INBOX", threadsUnread: unread.size });
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

  const world = { counts, seen, kv, env, mailbox, outlook, graphCalls, refused, FOLDERS, deadDevices, listen, marks, startedAt: started };

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

  /// One request whose answer is wanted whole (a picture, say). It is not written to `world.seen`.
  world.open = async (method, path) => {
    const pending = [];
    const realFetch = globalThis.fetch;
    globalThis.fetch = fakeFetch;
    try {
      const response = await module.default.fetch(new Request(`https://relay.test${path}`, { method }), env, { waitUntil: (promise) => pending.push(promise) });
      const bytes = new Uint8Array(await response.arrayBuffer());
      await Promise.all(pending);
      return { status: response.status, headers: response.headers, bytes };
    } finally {
      globalThis.fetch = realFetch;
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

  /// An app signs an Outlook account in, the way `world.register` does a Gmail one.
  world.registerOutlook = (accounts, extra = {}) =>
    world.request("POST", "/register", { headers: { "x-mach-secret": env.RELAY_SECRET }, body: { accounts: accounts.map((email) => ({ email, provider: "microsoft", refreshToken: `refresh-${email}`, clientId: "outlook-client" })), ...extra } });

  /// The watch Outlook holds for an account: its id, and the address and word it was told to use.
  world.watchOf = (email) => {
    const [id, made] = [...outlook(email).subscriptions].pop() || [];
    return id ? { id, path: made.notificationUrl.replace("https://relay.test", ""), clientState: made.clientState, made } : null;
  };

  /// What Outlook posts when an inbox changed. By default it is the account's own watch speaking.
  world.outlookSays = (email, { path = world.watchOf(email).path, clientState = world.watchOf(email).clientState, subscription = world.watchOf(email).id } = {}) =>
    world.request("POST", path, { body: { value: [{ subscriptionId: subscription, clientState, changeType: "created", resource: "me/messages/x" }] } });

  /// Mail in a made-up Outlook mailbox. New mail lands in the inbox a little in the future, so it is always
  /// later than the moment the relay started looking; pass `received` and `folder` for mail that is already there.
  let arrivals = 0;
  world.deliverOutlook = (email, { id, conversation = `c-${id}`, name = "Ada Lovelace", address = "ada@example.com", subject = "Hello", preview = "A short and friendly note", read = false, draft = false, classification = "focused", categories = [], folder = "inbox", received = new Date(Date.now() + 60000 + ++arrivals * 1000).toISOString() }) => {
    const message = { id, conversationId: conversation, subject, bodyPreview: preview, from: { emailAddress: { name, address } }, isRead: read, isDraft: draft, inferenceClassification: classification, categories, parentFolderId: FOLDERS[folder] || folder, receivedDateTime: received };
    outlook(email).messages.set(id, message);
    return message;
  };

  /// The relay's whole record of an account, as the store holds it.
  world.account = (email) => (kv.has(`account:${email}`) ? JSON.parse(kv.get(`account:${email}`).value) : null);

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
