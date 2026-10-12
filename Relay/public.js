// Mach's public push relay: the one the App Store and TestFlight builds use, for Outlook accounts.
//
// It is built to know as little as it can. It never sees a Microsoft sign-in, an email address or a word of mail:
//   - The phone makes up a random id and a random secret for each Outlook account, registers them here with its
//     Apple push address, and then asks Outlook itself (with the sign-in that never leaves the phone) to call
//     /v1/outlook/<id> whenever mail arrives, quoting the secret.
//   - Outlook's call names the new message by an opaque id and nothing else. The relay checks the secret and sends
//     the phone a push that carries only that id. The phone then asks Outlook for the sender and subject itself and
//     writes them on the banner.
// What is kept, per account on a phone: a fingerprint of the id (the key), a fingerprint of the secret, and the
// push address, encrypted. It goes when the account is signed out, when Apple says the phone is gone, or by itself
// after fifteen days without the app. There is no secret shared between people: knowing your own id and secret
// opens nothing but your own record.

const DAY = 86400000;
const KEEP_SECONDS = 15 * 86400;

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlText = (text) => b64url(new TextEncoder().encode(text));
const unb64 = (text) => Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function fingerprint(text) {
  return b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

function safeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// The id and the secret are random and long; anything else is not from the app.
const wellFormed = (word) => typeof word === "string" && /^[A-Za-z0-9_-]{32,128}$/.test(word);

let storeKey = null;
async function key(env) {
  if (!storeKey) storeKey = await crypto.subtle.importKey("raw", unb64(env.STORE_KEY), "AES-GCM", false, ["encrypt", "decrypt"]);
  return storeKey;
}

/// Push addresses are encrypted before they are stored, with a key only the running relay holds.
async function seal(env, text) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(env), new TextEncoder().encode(text));
  return `${b64url(iv)}.${b64url(sealed)}`;
}

async function unseal(env, text) {
  const [iv, sealed] = text.split(".");
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(iv) }, await key(env), unb64(sealed)));
}

// A little memory in front of the store, so a run of new mail reads a record once.
const held = new Map();

async function load(env, id) {
  const name = `w:${await fingerprint(id)}`;
  const kept = held.get(name);
  if (kept && kept.until > Date.now()) return { name, record: kept.record };
  const record = await env.STORE.get(name, "json");
  held.set(name, { record, until: Date.now() + 60000 });
  if (held.size > 5000) held.clear();
  return { name, record };
}

async function save(env, name, record) {
  await env.STORE.put(name, JSON.stringify(record), { expirationTtl: KEEP_SECONDS });
  held.set(name, { record, until: Date.now() + 60000 });
}

async function remove(env, name) {
  await env.STORE.delete(name);
  held.delete(name);
}

// How much one caller may ask in a while. Kept in memory: enough to stop a flood, never a reason to store who called.
const counters = new Map();
function allowed(who, limit, windowMs) {
  const now = Date.now();
  const entry = counters.get(who);
  if (!entry || now - entry.since > windowMs) {
    if (counters.size > 20000) counters.clear();
    counters.set(who, { since: now, count: 1 });
    return true;
  }
  entry.count++;
  return entry.count <= limit;
}

/// The phone says: this id, this secret, this push address. Saying it again with the same secret refreshes it;
/// with another secret it is refused, so nobody can take over an id that is not theirs.
async function register(request, env) {
  const body = await request.json().catch(() => null);
  if (!body || !wellFormed(body.id) || !wellFormed(body.secret) || !/^[0-9a-f]{64,200}$/.test(body.deviceToken || "")) return json({ error: "bad request" }, 400);
  const { name, record } = await load(env, body.id);
  const secret = await fingerprint(body.secret);
  if (record && !safeEqual(record.s, secret)) return json({ error: "forbidden" }, 403);
  const sandbox = !!body.sandbox;
  const same = record && record.sb === sandbox && (await unseal(env, record.d).catch(() => "")) === body.deviceToken;
  // Said on every launch; written only when something is different or the record is getting old.
  if (!same || Date.now() - record.at > DAY) await save(env, name, { s: secret, d: await seal(env, body.deviceToken), sb: sandbox, at: Date.now() });
  return json({ ok: true, keptDays: KEEP_SECONDS / 86400 });
}

/// Signed out, or "delete what you hold about me": the record goes, at once.
async function forget(request, env) {
  const body = await request.json().catch(() => null);
  if (!body || !wellFormed(body.id) || !wellFormed(body.secret)) return json({ error: "bad request" }, 400);
  const { name, record } = await load(env, body.id);
  if (record && !safeEqual(record.s, await fingerprint(body.secret))) return json({ error: "forbidden" }, 403);
  if (record) await remove(env, name);
  return json({ ok: true });
}

let apnsToken = null;
async function apnsJWT(env) {
  const now = Math.floor(Date.now() / 1000);
  if (apnsToken && now - apnsToken.at < 2400) return apnsToken.value;
  const pem = env.APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const signer = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64urlText(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = b64urlText(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, new TextEncoder().encode(`${head}.${claims}`));
  apnsToken = { at: now, value: `${head}.${claims}.${b64url(signature)}` };
  return apnsToken.value;
}

/// One push for one new message. It says nothing about the mail: the phone fills the banner in itself. The words
/// here are only seen if the phone could not (no connection in that moment).
/// Returns false when Apple says the phone is gone.
async function push(env, record, id, message) {
  const device = await unseal(env, record.d);
  const response = await fetch(`https://${record.sb ? "api.sandbox.push.apple.com" : "api.push.apple.com"}/3/device/${device}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJWT(env)}`,
      "apns-topic": env.BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // The same name the app gives its own banner for this message, so it can never show twice.
      "apns-collapse-id": (await fingerprint(message)).slice(0, 40),
    },
    body: JSON.stringify({
      aps: { alert: { title: "New mail", body: "Open Mach to read it." }, sound: "default", "mutable-content": 1, "content-available": 1 },
      mach: { id, message },
    }),
  });
  if (response.ok) return true;
  const reason = (await response.json().catch(() => ({}))).reason || "";
  console.log(`apns ${response.status} ${reason}`);
  return !(response.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered");
}

/// Outlook calling. First, once, to check the address is listening (it wants a word said back). After that, each
/// time mail arrives: which watch, the secret, and the new message's id.
async function outlook(request, env, ctx, id, url) {
  if (!wellFormed(id)) return json({ error: "not found" }, 404);
  const { name, record } = await load(env, id);
  if (!record) return json({ error: "not found" }, 404);
  const proof = url.searchParams.get("validationToken");
  if (proof !== null) return new Response(proof, { status: 200, headers: { "content-type": "text/plain" } });
  const body = await request.json().catch(() => ({}));
  const work = (async () => {
    const seen = new Set();
    for (const item of (body.value || []).slice(0, 20)) {
      const message = item.resourceData?.id;
      if (item.changeType !== "created" || typeof message !== "string" || !message || message.length > 512 || seen.has(message)) continue;
      if (!safeEqual(await fingerprint(String(item.clientState || "")), record.s)) continue;
      seen.add(message);
      // A mailbox does not get thirty mails a minute; something that does is not mail.
      if (!allowed(`push ${name}`, 30, 60000)) break;
      if (!(await push(env, record, id, message))) {
        await remove(env, name);
        break;
      }
    }
  })().catch((error) => console.log(`outlook: ${error}`));
  ctx.waitUntil(work);
  // Always acknowledged, and quickly, or Outlook stops sending.
  return new Response(null, { status: 202 });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const caller = request.headers.get("cf-connecting-ip") || "unknown";
    try {
      if (request.method === "POST" && url.pathname === "/v1/register") {
        if (!allowed(`register ${caller}`, 60, 600000)) return json({ error: "slow down" }, 429);
        return await register(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/forget") {
        if (!allowed(`register ${caller}`, 60, 600000)) return json({ error: "slow down" }, 429);
        return await forget(request, env);
      }
      if (request.method === "POST" && url.pathname.startsWith("/v1/outlook/")) {
        return await outlook(request, env, ctx, url.pathname.slice(12), url);
      }
    } catch (error) {
      console.log(String(error));
      return json({ error: "failed" }, 500);
    }
    return new Response("Mach push", { status: 200 });
  },
};
