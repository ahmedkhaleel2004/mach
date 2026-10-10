// Mach push relay: a Cloudflare Worker you deploy to your own account.
//
// The iPhone app registers its device token and its accounts here. The relay then learns about new mail in one of
// two ways and sends an Apple push for each new message that deserves one:
//   - Gmail "watch" (instant): Gmail publishes to a Google Pub/Sub topic, which posts to /pubsub/<secret>.
//     Needs a topic in the same Google project as the sign-in key (see README).
//   - Polling (within a minute): a cron asks Gmail's change log what is new. Used for accounts with no topic.
//
// It holds refresh tokens for the accounts it watches, so run it only under your own control.

/// Holds the open connections from running apps and tells them the instant an account has something new.
/// The apps then fetch the change themselves, so nothing about the mail passes through here.
export class Hub {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.queues = new Map();
    // What only the hub can keep between events: the account records (it is their only writer) and its storage.
    this.kept = { accounts: new Map(), storage: state.storage };
    // Every running app says "ping" every 25 seconds. Cloudflare answers "pong" itself, without waking the hub.
    if (state.setWebSocketAutoResponse && typeof WebSocketRequestResponsePair !== "undefined") {
      state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    }
  }

  /// Everything that reads and then rewrites an account's record runs here, one at a time per account.
  /// Gmail often sends several notifications for one message; without this they would each push it.
  serial(email, work) {
    const next = (this.queues.get(email) || Promise.resolve()).then(work, work);
    this.queues.set(email, next.catch(() => {}));
    return next;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const email = url.searchParams.get("email") || "";
    if (url.pathname === "/event") {
      // A Gmail notification: running apps hear at once, then the phones are pushed. One call does both.
      this.notify(email);
      return json(await this.serial(email, () => check(this.env, email, this.kept, url.searchParams.get("historyId"))).catch((error) => ({ error: String(error) })));
    }
    if (url.pathname === "/check") {
      return json(await this.serial(email, () => check(this.env, email, this.kept)).catch((error) => ({ error: String(error) })));
    }
    if (url.pathname === "/wake") {
      await this.serial(email, () => wake(this.env, email, this.kept)).catch((error) => console.log(String(error)));
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/renew") {
      return json(await this.serial(email, () => renew(this.env, email, this.kept)).catch((error) => ({ error: String(error) })));
    }
    if (url.pathname === "/account") {
      const entry = await request.json();
      return json(await this.serial(email, () => registerAccount(this.env, email, entry, this.kept)));
    }
    if (url.pathname === "/forget") {
      await this.serial(email, () => forget(this.env, email, this.kept));
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/notify") {
      this.notify(email);
      return new Response(null, { status: 204 });
    }
    const emails = (url.searchParams.get("emails") || "").toLowerCase().split(",").filter(Boolean).slice(0, 10);
    const pair = new WebSocketPair();
    this.state.acceptWebSocket(pair[1], emails);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  notify(email) {
    for (const socket of this.state.getWebSockets(email)) {
      try {
        socket.send(JSON.stringify({ email, at: Date.now() }));
      } catch {}
    }
  }

  webSocketMessage(socket, message) {
    if (message === "ping") socket.send("pong");
  }

  webSocketClose(socket) {
    try {
      socket.close();
    } catch {}
  }
}

function hub(env) {
  return env.HUB.get(env.HUB.idFromName("hub"));
}

async function announce(env, email) {
  try {
    await hub(env).fetch(`https://hub/notify?email=${encodeURIComponent(email)}`);
  } catch (error) {
    console.log(`hub: ${error}`);
  }
}

const BULK = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS"];
const GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me";
const GRAPH = "https://graph.microsoft.com/v1.0";
const MICROSOFT_TOKEN = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
const isOutlook = (account) => account.provider === "microsoft";

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlText = (text) => b64url(new TextEncoder().encode(text));

function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/// `kept` is the hub's memory (see Hub). The hub is the only writer of account records, so what it last read or
/// wrote is what the store holds, and it need not ask the store again. Callers outside the hub pass nothing.
async function loadAccount(env, email, kept) {
  const remembered = kept?.accounts.get(email);
  if (remembered !== undefined) return JSON.parse(remembered);
  const text = await env.STORE.get(`account:${email}`);
  kept?.accounts.set(email, text === null ? "null" : text);
  return text === null ? null : JSON.parse(text);
}

async function saveAccount(env, account, kept) {
  const text = JSON.stringify(account);
  await env.STORE.put(`account:${account.email}`, text);
  kept?.accounts.set(account.email, text);
}

// Google access tokens, kept in memory in front of the store. Keyed to the refresh token they came from, so a
// new sign-in never reuses an old one.
const tokens = new Map();
const refreshing = new Map();
const early = new Map();

/// Asks the store for an account's token before it is known to be needed, so that read runs beside the read of
/// the account record instead of after it. Used when the hub has just woken and remembers nothing.
function readTokenEarly(env, email) {
  if (tokens.has(email) || early.has(email)) return;
  early.set(email, { at: Date.now(), answer: env.STORE.getWithMetadata(`token:${email}`).catch(() => null) });
}

function forgetToken(email) {
  tokens.delete(email);
}

async function accessToken(env, account) {
  const held = tokens.get(account.email);
  if (held && held.refreshToken === account.refreshToken && held.until > Date.now()) return held.value;
  // Several calls at once (one per new message) share one trip to the store, and one to Google if it comes to that.
  const key = `${account.email} ${account.refreshToken}`;
  let pending = refreshing.get(key);
  if (!pending) {
    pending = fetchAccessToken(env, account).finally(() => refreshing.delete(key));
    refreshing.set(key, pending);
  }
  return pending;
}

async function fetchAccessToken(env, account) {
  const remember = (value, until) => tokens.set(account.email, { value, refreshToken: account.refreshToken, until });
  const asked = early.get(account.email);
  early.delete(account.email);
  // An early answer is only good for the event that asked for it.
  const cached = (asked && Date.now() - asked.at < 5000 && (await asked.answer)) || (await env.STORE.getWithMetadata(`token:${account.email}`));
  if (cached.value) {
    // The store drops a token five minutes before Google does. Without a recorded expiry (a token an older
    // version of this relay stored), trust it for two minutes only.
    remember(cached.value, cached.metadata?.until || Date.now() + 120000);
    return cached.value;
  }
  const form = new URLSearchParams({ grant_type: "refresh_token", refresh_token: account.refreshToken, client_id: account.clientId });
  if (account.clientSecret) form.set("client_secret", account.clientSecret);
  const response = await fetch(isOutlook(account) ? MICROSOFT_TOKEN : "https://oauth2.googleapis.com/token", { method: "POST", body: form });
  const data = await response.json();
  if (!data.access_token) throw new Error(`token refresh failed for ${account.email}: ${data.error || response.status}${isOutlook(account) && data.error_codes ? ` ${data.error_codes}` : ""}`);
  const ttl = Math.max(60, (data.expires_in || 3600) - 300);
  await env.STORE.put(`token:${account.email}`, data.access_token, { expirationTtl: ttl, metadata: { until: Date.now() + ttl * 1000 } });
  remember(data.access_token, Date.now() + ttl * 1000);
  return data.access_token;
}

async function gmail(env, account, path, init = {}) {
  const token = await accessToken(env, account);
  const response = await fetch(GMAIL + path, { ...init, headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(init.headers || {}) } });
  if (response.status === 401) {
    forgetToken(account.email);
    await env.STORE.delete(`token:${account.email}`);
  }
  return response;
}

function topicFor(env, account) {
  try {
    const topics = JSON.parse(env.TOPICS || "{}");
    return topics[(account.clientId || "").split("-")[0]] || null;
  } catch {
    return null;
  }
}

/// Starts (or renews) Gmail's own notifications for the account when a topic exists for its Google project.
async function watch(env, account) {
  const topic = topicFor(env, account);
  if (!topic) {
    account.watchExpiry = 0;
    return;
  }
  const response = await gmail(env, account, "/watch", {
    method: "POST",
    body: JSON.stringify({ topicName: topic, labelIds: ["INBOX"], labelFilterBehavior: "INCLUDE" }),
  });
  const data = await response.json();
  if (response.ok) {
    account.watchExpiry = Number(data.expiration || 0);
    if (!account.historyId) account.historyId = data.historyId;
  } else {
    account.watchExpiry = 0;
    account.watchError = data.error?.message || String(response.status);
  }
}

/// One call to Outlook. Ids are asked for in the form that survives a move between folders, which is the form
/// the apps know a message by.
async function graph(env, account, path, init = {}) {
  const token = await accessToken(env, account);
  const response = await fetch(path.startsWith("https://") ? path : GRAPH + path, {
    ...init,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", prefer: 'IdType="ImmutableId"', ...(init.headers || {}) },
  });
  if (response.status === 401) {
    forgetToken(account.email);
    await env.STORE.delete(`token:${account.email}`);
  }
  return response;
}

/// Outlook tells this address about every change in the inbox. It asks for no topic and no setup, only an address
/// it can reach, so every Outlook account is instant. A watch lasts under a week and is renewed by the cron.
async function watchOutlook(env, account) {
  if (!account.origin) {
    account.watchExpiry = 0;
    return;
  }
  const expirationDateTime = new Date(Date.now() + 6 * 86400000).toISOString();
  if (account.subscription) {
    const renewed = await graph(env, account, `/subscriptions/${account.subscription}`, { method: "PATCH", body: JSON.stringify({ expirationDateTime }) });
    if (renewed.ok) {
      account.watchExpiry = Date.parse(expirationDateTime);
      return;
    }
  }
  const response = await graph(env, account, "/subscriptions", {
    method: "POST",
    body: JSON.stringify({
      changeType: "created,updated,deleted",
      notificationUrl: `${account.origin}/outlook/${env.RELAY_SECRET}?email=${encodeURIComponent(account.email)}`,
      resource: "me/mailFolders('inbox')/messages",
      expirationDateTime,
      clientState: await clientState(env, account.email),
    }),
  });
  const data = await response.json().catch(() => ({}));
  if (response.ok) {
    account.subscription = data.id;
    account.watchExpiry = Date.parse(data.expirationDateTime || expirationDateTime);
    delete account.watchError;
  } else {
    account.subscription = "";
    account.watchExpiry = 0;
    account.watchError = data.error?.message || String(response.status);
  }
}

/// What Outlook must say back with each notification, so nobody else can make this relay check an account.
async function clientState(env, email) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${env.RELAY_SECRET} ${email}`));
  return b64url(digest).slice(0, 40);
}

/// A short stand-in for an Outlook id, which is too long for Apple to group banners by.
async function shortId(id) {
  return b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id))).slice(0, 40);
}

/// Unread conversations in an Outlook inbox, or null when Outlook would not say.
async function unreadOutlook(env, account) {
  try {
    const response = await graph(env, account, "/me/mailFolders/inbox/messages?$filter=isRead%20eq%20false&$select=conversationId&$top=500");
    if (!response.ok) return null;
    return new Set(((await response.json()).value || []).map((message) => message.conversationId)).size;
  } catch {
    return null;
  }
}

/// The same job as `check`, for Outlook: pushes each message that reached the inbox since the last look.
/// Outlook has no change log to keep a place in; the place kept is the arrival time of the newest mail seen.
async function checkOutlook(env, account, kept) {
  const email = account.email;
  if (!account.since) {
    account.since = new Date().toISOString();
    await saveAccount(env, account, kept);
    return { email, started: true };
  }
  const query = `$filter=receivedDateTime%20gt%20${encodeURIComponent(account.since)}&$orderby=receivedDateTime%20desc&$top=10`
    + "&$select=id,conversationId,subject,bodyPreview,from,isRead,isDraft,inferenceClassification,receivedDateTime";
  const response = await graph(env, account, `/me/mailFolders/inbox/messages?${query}`);
  if (!response.ok) return { email, error: response.status };
  const found = ((await response.json()).value || []).reverse();
  // An account Outlook is not notifying us about is found by this polling; tell running apps now.
  if (found.length && !(account.watchExpiry > Date.now())) await announce(env, email);
  let devices = account.devices;
  const all = kept ? await badges(kept) : null;
  const before = all?.[email];
  const unread = all && devices.length ? await unreadOutlook(env, account) : null;
  if (unread !== null) all[email] = { unread, tokens: devices.map((device) => device.token) };
  const badged = (device) => (all?.[email] ? { badge: badgeFor(all, device.token) } : {});
  let sent = 0;
  const mine = email.toLowerCase();
  for (const message of devices.length ? found.slice(-5) : []) {
    const from = message.from?.emailAddress || {};
    const address = (from.address || "").toLowerCase();
    // With a single inbox (the default) every new mail is announced; with the split, only what Outlook calls focused.
    const wanted = account.allMail !== false || message.inferenceClassification !== "other";
    if (message.isRead || message.isDraft || address === mine || !wanted) continue;
    const thread = message.conversationId || message.id;
    const name = from.name || address.split("@")[0];
    const payload = {
      aps: {
        alert: { title: name, subtitle: message.subject || "", body: (message.bodyPreview || "").replace(/[\u200b\u200c\u200d\u034f\ufeff\u00ad]/g, "").replace(/\s+/g, " ").trim() },
        sound: "default",
        "thread-id": `${email}/${thread}`,
        "content-available": 1,
        "mutable-content": 1,
      },
      account: email,
      thread,
      senderEmail: address,
      senderName: name,
      senderPhoto: "",
    };
    const collapse = await shortId(message.id);
    const reached = await Promise.all(devices.map((device) => push(env, device, { ...payload, aps: { ...payload.aps, ...badged(device) }, avatars: device.avatars !== false }, collapse, kept)));
    devices = devices.filter((_, position) => reached[position]);
    sent++;
  }
  if (unread !== null) {
    if (!sent && before?.unread !== unread) {
      const reached = await Promise.all(devices.map((device) => push(env, device, { aps: { ...badged(device), "content-available": 1 } }, "badge", kept)));
      devices = devices.filter((_, position) => reached[position]);
    }
    all[email].tokens = devices.map((device) => device.token);
    if (before?.unread !== unread || String(before?.tokens) !== String(all[email].tokens)) await kept.storage.put("badges", all).catch(() => {});
  }
  const newest = found.length ? found[found.length - 1].receivedDateTime : account.since;
  if (newest !== account.since || devices.length !== account.devices.length) {
    account.since = newest;
    account.devices = devices;
    await saveAccount(env, account, kept);
  }
  return { email, sent };
}

let apnsToken = null;

/// Apple wants its sign-in token reused for a good while, not made afresh for every push. The hub is put to sleep
/// whenever it is quiet and forgets everything in memory, so it also keeps the token in its own storage.
async function apnsJWT(env, kept) {
  const now = Math.floor(Date.now() / 1000);
  if (apnsToken && now - apnsToken.at < 2400) return apnsToken.value;
  if (kept) {
    const stored = await kept.storage.get("apns").catch(() => null);
    // Another push may have made one while this one was waiting.
    if (apnsToken && now - apnsToken.at < 2400) return apnsToken.value;
    if (stored && stored.key === env.APNS_KEY_ID && now - stored.at < 2400) {
      apnsToken = { at: stored.at, value: stored.value };
      return apnsToken.value;
    }
  }
  const pem = env.APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`));
  apnsToken = { at: now, value: `${head}.${claims}.${b64url(signature)}` };
  if (kept) await kept.storage.put("apns", { at: now, key: env.APNS_KEY_ID, value: apnsToken.value }).catch(() => {});
  return apnsToken.value;
}

/// Returns false when Apple says the device token is dead and should be forgotten.
async function push(env, device, payload, collapseId, kept) {
  const host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJWT(env, kept)}`,
      "apns-topic": env.BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": collapseId,
    },
    body: JSON.stringify(payload),
  });
  if (response.ok) return true;
  const reason = (await response.json().catch(() => ({}))).reason || "";
  console.log(`apns ${response.status} ${reason}`);
  return !(response.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered");
}

/// The number on the app's icon is the unread conversations in every inbox the phone holds. Each account's part of
/// it (its count, and the phones it is on) is kept here, in the hub's own storage, so a push for one account can
/// carry the total without asking Gmail about the others.
async function badges(kept) {
  if (!kept.badges) kept.badges = (await kept.storage.get("badges").catch(() => null)) || {};
  return kept.badges;
}

function badgeFor(all, token) {
  let total = 0;
  for (const entry of Object.values(all)) if (entry.tokens.includes(token)) total += entry.unread;
  return total;
}

/// Unread conversations in the account's inbox, or null when Gmail would not say.
async function unreadCount(env, account) {
  try {
    const response = await gmail(env, account, "/labels/INBOX");
    return response.ok ? Number((await response.json()).threadsUnread || 0) : null;
  } catch {
    return null;
  }
}

/// The sender's Google profile picture, from the account's own contacts, so the banner can show a real face.
/// The whole list is fetched once a day and kept; mail arriving in between costs nothing extra.
// Kept in memory for ten minutes at a time, so a run of new mail reads and parses the (large) list once.
const people = new Map();

async function photoFor(env, account, sender) {
  try {
    const held = people.get(account.email);
    let map = held && held.until > Date.now() ? await held.map : null;
    if (!map) {
      const loading = loadPeople(env, account);
      people.set(account.email, { map: loading, until: Date.now() + 600000 });
      try {
        map = await loading;
      } catch (error) {
        people.delete(account.email);
        throw error;
      }
    }
    const url = map[sender];
    return url ? url.replace("=s100", "=s192") : "";
  } catch {
    return "";
  }
}

async function loadPeople(env, account) {
  const key = `people:${account.email}`;
  let map = await env.STORE.get(key, "json");
  if (map) return map;
  map = {};
  const add = (person) => {
    const photo = (person.photos || []).find((p) => !p.default && p.url);
    if (!photo) return;
    for (const item of person.emailAddresses || []) if (item.value && !map[item.value.toLowerCase()]) map[item.value.toLowerCase()] = photo.url;
  };
  const token = await accessToken(env, account);
  const get = async (path) => {
    const response = await fetch(`https://people.googleapis.com/v1${path}`, { headers: { authorization: `Bearer ${token}` } });
    return response.ok ? response.json() : null;
  };
  const all = async (path, field) => {
    const found = [];
    let pageToken = "";
    for (let page = 0; page < 5; page++) {
      const data = await get(path + (pageToken ? `&pageToken=${pageToken}` : ""));
      if (!data) break;
      found.push(...(data[field] || []));
      pageToken = data.nextPageToken || "";
      if (!pageToken) break;
    }
    return found;
  };
  // The three lists are asked for side by side and then read in the order that decides whose picture wins:
  // your own, then your contacts, then people you have only written to.
  const [me, connections, others] = await Promise.all([
    get("/people/me?personFields=photos,emailAddresses"),
    all("/people/me/connections?personFields=emailAddresses,photos&pageSize=1000", "connections"),
    all("/otherContacts?readMask=emailAddresses,photos&sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_PROFILE&pageSize=1000", "otherContacts"),
  ]);
  if (me) add(me);
  for (const person of connections) add(person);
  for (const person of others) add(person);
  // An empty answer usually means the sign-in has no contacts access; ask again sooner.
  await env.STORE.put(key, JSON.stringify(map), { expirationTtl: Object.keys(map).length ? 86400 : 3600 });
  return map;
}

function header(message, name) {
  return (message.payload?.headers || []).find((h) => h.name.toLowerCase() === name)?.value || "";
}

function senderEmail(from) {
  const match = from.match(/<([^>]+)>/);
  return (match ? match[1] : from).trim().toLowerCase();
}

function senderName(from) {
  const match = from.match(/^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/);
  if (match) return match[1].trim() || match[2].split("@")[0];
  return from.split("@")[0];
}

function decodeEntities(text) {
  return (text || "").replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n))).replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
}

/// Looks at what changed since the last check and pushes each new message that belongs in the main inbox.
///
/// `notified` is the place in Gmail's change log a notification speaks of. Gmail often says the same thing several
/// times; when everything up to that place has been looked at already there is nothing to ask Gmail.
async function check(env, email, kept, notified) {
  if (kept && !kept.accounts.has(email)) readTokenEarly(env, email);
  const account = await loadAccount(env, email, kept);
  if (!account) {
    early.delete(email);
    return { email, skipped: true };
  }
  account.devices = account.devices || [];
  if (isOutlook(account)) return checkOutlook(env, account, kept);
  if (!account.historyId) {
    const profile = await (await gmail(env, account, "/profile")).json();
    account.historyId = profile.historyId;
    await saveAccount(env, account, kept);
    return { email, started: true };
  }
  if (notified && alreadySeen(notified, account.historyId)) return { email, sent: 0, repeat: true };
  const added = new Map();
  let latest = account.historyId;
  let pageToken = "";
  do {
    const query = new URLSearchParams({ startHistoryId: account.historyId, historyTypes: "messageAdded", labelId: "INBOX", maxResults: "100" });
    if (pageToken) query.set("pageToken", pageToken);
    const response = await gmail(env, account, `/history?${query}`);
    if (response.status === 404) {
      // The change log does not go back that far. Start again from now.
      const profile = await (await gmail(env, account, "/profile")).json();
      account.historyId = profile.historyId;
      await saveAccount(env, account, kept);
      return { email, reset: true };
    }
    if (!response.ok) return { email, error: response.status };
    const page = await response.json();
    for (const record of page.history || []) {
      for (const item of record.messagesAdded || []) {
        const labels = item.message.labelIds || [];
        // With a single inbox (the default) every new mail is announced; with the split, only mail from people.
        const wanted = account.allMail !== false || !labels.some((l) => BULK.includes(l));
        if (labels.includes("INBOX") && labels.includes("UNREAD") && !labels.includes("SENT") && wanted) {
          added.set(item.message.id, item.message.threadId);
        }
      }
    }
    if (page.historyId) latest = page.historyId;
    pageToken = page.nextPageToken || "";
  } while (pageToken);

  // Accounts Gmail does not notify us about are found by polling; tell running apps now.
  if (latest !== account.historyId && !(account.watchExpiry > Date.now())) await announce(env, email);
  let sent = 0;
  let devices = account.devices;
  // Anything that changed in the inbox (new mail, but also mail read or archived somewhere else) can change the
  // number on the icon. Gmail is asked for it while the new messages are being fetched, not after.
  const all = kept ? await badges(kept) : null;
  const before = all?.[email];
  const counting = all && devices.length && (latest !== account.historyId || !before) ? unreadCount(env, account) : null;
  // Every new message is asked for at the same moment; the pushes then go out in the order the mail arrived.
  const wanted = devices.length ? [...added].slice(-5) : [];
  // The list of contact pictures is read while Gmail is being asked, not after.
  if (wanted.length) photoFor(env, account, "");
  const fetched = await Promise.allSettled(wanted.map(async ([id]) => {
    const response = await gmail(env, account, `/messages/${id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject`);
    return response.ok ? response.json() : null;
  }));
  const unread = counting ? await counting : null;
  if (unread !== null) all[email] = { unread, tokens: devices.map((device) => device.token) };
  const badged = (device) => (all?.[email] ? { badge: badgeFor(all, device.token) } : {});
  for (const [index, [id, threadId]] of wanted.entries()) {
    if (fetched[index].status === "rejected") throw fetched[index].reason;
    const message = fetched[index].value;
    if (!message) continue;
    if (!(message.labelIds || []).includes("UNREAD")) continue;
    const payload = {
      aps: {
        alert: { title: senderName(header(message, "from")), subtitle: header(message, "subject"), body: decodeEntities(message.snippet).replace(/[​‌‍͏﻿­]/g, "").trim() },
        sound: "default",
        "thread-id": `${email}/${threadId}`,
        "content-available": 1,
        // Lets the app's notification extension put the sender's picture on the banner.
        "mutable-content": 1,
      },
      account: email,
      thread: threadId,
      senderEmail: senderEmail(header(message, "from")),
      senderName: senderName(header(message, "from")),
      senderPhoto: await photoFor(env, account, senderEmail(header(message, "from"))),
    };
    // All of this account's phones at once.
    const reached = await Promise.all(devices.map((device) => push(env, device, { ...payload, aps: { ...payload.aps, ...badged(device) }, avatars: device.avatars !== false }, id, kept)));
    devices = devices.filter((_, position) => reached[position]);
    sent++;
  }
  if (unread !== null) {
    // Nothing new to announce, but the count moved: mail was read or archived somewhere else. The icon is
    // corrected, silently, and the app is woken for a moment to take down the banners of that mail.
    if (!sent && before?.unread !== unread) {
      const reached = await Promise.all(devices.map((device) => push(env, device, { aps: { ...badged(device), "content-available": 1 } }, "badge", kept)));
      devices = devices.filter((_, position) => reached[position]);
    }
    all[email].tokens = devices.map((device) => device.token);
    if (before?.unread !== unread || String(before?.tokens) !== String(all[email].tokens)) await kept.storage.put("badges", all).catch(() => {});
  }
  if (latest !== account.historyId || devices.length !== account.devices.length) {
    account.historyId = latest;
    account.devices = devices;
    await saveAccount(env, account, kept);
  }
  return { email, sent };
}

/// True when place `a` in Gmail's change log is at or before place `b`. The places are large whole numbers.
function alreadySeen(a, b) {
  try {
    return BigInt(a) <= BigInt(b);
  } catch {
    return false;
  }
}

/// Renews Gmail's notifications for an account when they are close to running out. Runs inside the hub, like
/// everything else that rewrites an account's record.
async function renew(env, email, kept) {
  const account = await loadAccount(env, email, kept);
  if (!account) return { email, skipped: true };
  if ((isOutlook(account) || topicFor(env, account)) && (account.watchExpiry || 0) < Date.now() + 2 * 86400000) {
    await (isOutlook(account) ? watchOutlook(env, account) : watch(env, account));
    await saveAccount(env, account, kept);
  }
  return { email, watchExpiry: account.watchExpiry || 0 };
}

const SNOOZE_PREFIX = "Snoozed/";

/// Brings snoozed mail back when its time comes, so it returns even if no Mac or phone is awake.
/// A snooze is a hidden Gmail label named "Snoozed/<time>"; this removes the label and puts the mail back, unread.
async function wake(env, email, kept) {
  const account = await loadAccount(env, email, kept);
  // An Outlook snooze is a category on the mail, which Outlook cannot be asked to list; the apps bring those back.
  if (!account || isOutlook(account)) return;
  const listing = await gmail(env, account, "/labels");
  if (!listing.ok) return;
  const labels = (await listing.json()).labels || [];
  for (const label of labels) {
    if (!label.name.startsWith(SNOOZE_PREFIX)) continue;
    const due = Date.parse(label.name.slice(SNOOZE_PREFIX.length));
    if (!Number.isFinite(due) || due > Date.now()) continue;
    const found = await gmail(env, account, `/threads?labelIds=${encodeURIComponent(label.id)}&maxResults=100`);
    const threads = found.ok ? (await found.json()).threads || [] : [];
    for (const thread of threads) {
      const changed = await gmail(env, account, `/threads/${thread.id}/modify`, {
        method: "POST",
        body: JSON.stringify({ addLabelIds: ["INBOX", "UNREAD"], removeLabelIds: [label.id] }),
      });
      if (!changed.ok || !account.devices?.length) continue;
      const details = await gmail(env, account, `/threads/${thread.id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject`);
      const last = details.ok ? ((await details.json()).messages || []).pop() : null;
      if (!last) continue;
      const payload = {
        aps: {
          alert: { title: senderName(header(last, "from")), subtitle: header(last, "subject"), body: "Back in your inbox." },
          sound: "default", "thread-id": `${email}/${thread.id}`, "content-available": 1, "mutable-content": 1,
        },
        account: email, thread: thread.id,
        senderEmail: senderEmail(header(last, "from")), senderName: senderName(header(last, "from")),
        senderPhoto: await photoFor(env, account, senderEmail(header(last, "from"))),
      };
      for (const device of account.devices) await push(env, device, { ...payload, avatars: device.avatars !== false }, last.id, kept);
    }
    // Only an emptied label is removed; if anything failed it is tried again next minute.
    if (found.ok) {
      const left = await gmail(env, account, `/threads?labelIds=${encodeURIComponent(label.id)}&maxResults=1`);
      if (left.ok && !((await left.json()).threads || []).length) await gmail(env, account, `/labels/${label.id}`, { method: "DELETE" });
    }
    await announce(env, email);
  }
}

/// Adds or refreshes one account's record. Runs inside the hub so it cannot interleave with a check.
async function registerAccount(env, email, entry, kept) {
  const account = (await loadAccount(env, email, kept)) || { email, devices: [] };
  if (entry.provider === "microsoft") return registerOutlook(env, account, entry, kept);
  const changed = account.refreshToken !== entry.refreshToken || account.clientId !== entry.clientId
    || (account.allMail !== false) !== (entry.allMail !== false);
  account.allMail = entry.allMail !== false;
  account.refreshToken = entry.refreshToken;
  account.clientId = entry.clientId;
  account.clientSecret = entry.clientSecret || "";
  const before = JSON.stringify(account.devices);
  account.devices = (account.devices || []).filter((d) => d.token !== entry.deviceToken);
  if (entry.deviceToken) account.devices.push({ token: entry.deviceToken, sandbox: !!entry.sandbox, avatars: entry.avatars !== false });
  const needsWatch = !account.watchExpiry || account.watchExpiry < Date.now() + 2 * 86400000;
  if (changed) {
    forgetToken(email);
    await env.STORE.delete(`token:${email}`);
  }
  if (changed || needsWatch) await watch(env, account);
  if (!account.historyId) {
    const profile = await (await gmail(env, account, "/profile")).json();
    account.historyId = profile.historyId;
  }
  // Registration happens on every launch; only write when something is different.
  if (changed || needsWatch || before !== JSON.stringify(account.devices)) await saveAccount(env, account, kept);
  if (kept) {
    // The phone's badge counts this account from now on.
    const all = await badges(kept);
    const tokens = account.devices.map((device) => device.token);
    if (!all[email] || String(all[email].tokens) !== String(tokens)) {
      const unread = all[email]?.unread ?? (tokens.length ? await unreadCount(env, account) : null) ?? 0;
      all[email] = { unread, tokens };
      await kept.storage.put("badges", all).catch(() => {});
    }
  }
  return { email, instant: account.watchExpiry > Date.now() };
}

/// The same as `registerAccount`, for Outlook. Microsoft gives the app a new sign-in token with every use and
/// keeps the old ones working, so a different token here is the same sign-in and nothing is started over for it.
async function registerOutlook(env, account, entry, kept) {
  const email = account.email;
  const before = JSON.stringify(account);
  const fresh = account.provider !== "microsoft" || account.clientId !== entry.clientId || account.origin !== entry.origin;
  account.provider = "microsoft";
  account.allMail = entry.allMail !== false;
  account.refreshToken = entry.refreshToken;
  account.clientId = entry.clientId;
  account.clientSecret = "";
  // Where Outlook can reach this relay: the address the app itself reached it at.
  account.origin = entry.origin;
  account.devices = (account.devices || []).filter((d) => d.token !== entry.deviceToken);
  if (entry.deviceToken) account.devices.push({ token: entry.deviceToken, sandbox: !!entry.sandbox, avatars: entry.avatars !== false });
  if (fresh) {
    forgetToken(email);
    await env.STORE.delete(`token:${email}`);
    account.subscription = "";
  }
  if (fresh || !account.watchExpiry || account.watchExpiry < Date.now() + 2 * 86400000) await watchOutlook(env, account);
  if (!account.since) account.since = new Date().toISOString();
  if (before !== JSON.stringify(account)) await saveAccount(env, account, kept);
  if (kept) {
    const all = await badges(kept);
    const tokens = account.devices.map((device) => device.token);
    if (!all[email] || String(all[email].tokens) !== String(tokens)) {
      const unread = all[email]?.unread ?? (tokens.length ? await unreadOutlook(env, account) : null) ?? 0;
      all[email] = { unread, tokens };
      await kept.storage.put("badges", all).catch(() => {});
    }
  }
  return { email, instant: account.watchExpiry > Date.now() };
}

/// Signed out: stop the service's notifications and delete everything held for the account.
async function forget(env, email, kept) {
  const account = await loadAccount(env, email, kept);
  if (account && isOutlook(account)) {
    if (account.subscription) await graph(env, account, `/subscriptions/${account.subscription}`, { method: "DELETE" }).catch(() => {});
  } else if (account) await gmail(env, account, "/stop", { method: "POST" }).catch(() => {});
  await env.STORE.delete(`account:${email}`);
  kept?.accounts.delete(email);
  if (kept) {
    const all = await badges(kept);
    delete all[email];
    await kept.storage.put("badges", all).catch(() => {});
  }
  forgetToken(email);
  people.delete(email);
  await env.STORE.delete(`token:${email}`);
  const known = ((await env.STORE.get("accounts", "json")) || []).filter((e) => e !== email);
  await env.STORE.put("accounts", JSON.stringify(known));
}

async function register(request, env) {
  const body = await request.json();
  // A Mac registers with no device token: it only wants the account watched and listens on /live.
  const hasDevice = /^[0-9a-f]{64,200}$/.test(body.deviceToken || "");
  if ((body.deviceToken && !hasDevice) || !Array.isArray(body.accounts)) return json({ error: "bad request" }, 400);
  const emails = [];
  for (const entry of body.accounts.slice(0, 10)) {
    if (!entry.email || !entry.refreshToken || !entry.clientId) continue;
    const email = String(entry.email).toLowerCase();
    const response = await hub(env).fetch(`https://hub/account?email=${encodeURIComponent(email)}`, {
      method: "POST",
      body: JSON.stringify({ ...entry, origin: new URL(request.url).origin, deviceToken: hasDevice ? body.deviceToken : "", sandbox: !!body.sandbox, avatars: body.avatars !== false, allMail: body.allMail !== false }),
    });
    emails.push(await response.json());
  }
  const known = new Set((await env.STORE.get("accounts", "json")) || []);
  const size = known.size;
  for (const item of emails) known.add(item.email);
  if (known.size !== size) await env.STORE.put("accounts", JSON.stringify([...known]));
  return json({ ok: true, accounts: emails });
}

function runCheck(env, email) {
  return hub(env).fetch(`https://hub/check?email=${encodeURIComponent(email)}`).catch((error) => console.log(String(error)));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/register") {
      if (!safeEqual(request.headers.get("x-mach-secret") || "", env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      try {
        return await register(request, env);
      } catch (error) {
        return json({ error: String(error.message || error) }, 500);
      }
    }
    if (request.method === "POST" && url.pathname.startsWith("/pubsub/")) {
      if (!safeEqual(url.pathname.slice(8), env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      try {
        const envelope = await request.json();
        const data = JSON.parse(atob(envelope.message.data));
        const email = String(data.emailAddress).toLowerCase();
        // Running apps hear first; the Apple push follows as soon as the sender and subject are known.
        const place = /^\d+$/.test(String(data.historyId ?? "")) ? `&historyId=${data.historyId}` : "";
        ctx.waitUntil(hub(env).fetch(`https://hub/event?email=${encodeURIComponent(email)}${place}`).catch((error) => console.log(String(error))));
      } catch (error) {
        console.log(`bad pubsub message: ${error}`);
      }
      // Always acknowledge, or Google keeps redelivering.
      return new Response(null, { status: 204 });
    }
    if (request.method === "POST" && url.pathname.startsWith("/outlook/")) {
      if (!safeEqual(url.pathname.slice(9), env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      // Outlook first asks the address to say a word back, to prove it is listening.
      const proof = url.searchParams.get("validationToken");
      if (proof !== null) return new Response(proof, { status: 200, headers: { "content-type": "text/plain" } });
      try {
        const email = String(url.searchParams.get("email") || "").toLowerCase();
        const expected = await clientState(env, email);
        const body = await request.json();
        if (email && (body.value || []).some((item) => safeEqual(item.clientState || "", expected))) {
          ctx.waitUntil(hub(env).fetch(`https://hub/event?email=${encodeURIComponent(email)}`).catch((error) => console.log(String(error))));
        }
      } catch (error) {
        console.log(`bad outlook notification: ${error}`);
      }
      // Always acknowledged, and quickly, or Outlook stops sending.
      return new Response(null, { status: 202 });
    }
    if (request.method === "POST" && url.pathname === "/unregister") {
      if (!safeEqual(request.headers.get("x-mach-secret") || "", env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      const body = await request.json().catch(() => ({}));
      if (body.email) await hub(env).fetch(`https://hub/forget?email=${encodeURIComponent(String(body.email).toLowerCase())}`);
      return json({ ok: true });
    }
    if (url.pathname === "/live") {
      if (!safeEqual(request.headers.get("x-mach-secret") || "", env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      if (request.headers.get("upgrade") !== "websocket") return json({ error: "expected a websocket" }, 426);
      return hub(env).fetch(request);
    }
    if (request.method === "POST" && url.pathname === "/test") {
      // Sends a test banner to every registered device. For checking the Apple side works.
      if (!safeEqual(request.headers.get("x-mach-secret") || "", env.RELAY_SECRET)) return json({ error: "forbidden" }, 403);
      const results = [];
      for (const email of (await env.STORE.get("accounts", "json")) || []) {
        const account = await loadAccount(env, email);
        for (const device of account?.devices || []) {
          const ok = await push(env, device, {
            aps: { alert: { title: "You", subtitle: "Push is working", body: `New mail for ${email} will look like this.` }, sound: "default", "mutable-content": 1 },
            account: email, senderEmail: email, senderName: "You", senderPhoto: await photoFor(env, account, email), avatars: device.avatars !== false,
          }, "test");
          results.push({ email, ok });
        }
      }
      return json({ results });
    }
    return new Response("Mach push relay", { status: 200 });
  },

  async scheduled(event, env, ctx) {
    const emails = (await env.STORE.get("accounts", "json")) || [];
    for (const email of emails) {
      const account = await loadAccount(env, email);
      if (!account) continue;
      const hasTopic = isOutlook(account) || !!topicFor(env, account);
      if (hasTopic && (account.watchExpiry || 0) < Date.now() + 2 * 86400000) {
        // The hub rewrites the record; this only needs to know how long the renewed watch lasts.
        const renewed = await hub(env).fetch(`https://hub/renew?email=${encodeURIComponent(email)}`).then((response) => response.json()).catch((error) => ({ error: String(error) }));
        if (renewed.watchExpiry !== undefined) account.watchExpiry = renewed.watchExpiry;
      }
      ctx.waitUntil(hub(env).fetch(`https://hub/wake?email=${encodeURIComponent(email)}`).catch((error) => console.log(String(error))));
      // Accounts Gmail notifies us about are still checked every ten minutes, in case a notification was lost.
      const minute = new Date(event.scheduledTime).getUTCMinutes();
      if (!(account.watchExpiry > Date.now()) || minute % 10 === 0) {
        ctx.waitUntil(runCheck(env, email));
      }
    }
  },
};
