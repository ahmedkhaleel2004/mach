// Runs the relay in Cloudflare's own runtime on this machine (wrangler dev, local only, made-up secrets) and checks
// the parts that need no Gmail or Apple: it starts, doors stay shut without the secret, an app connection is kept,
// "ping" is answered, and a Gmail notification reaches the connected app.
//
//   cd Relay && bun test/smoke.js          (downloads wrangler on first use; never deploys, never calls Google)
import { mkdtempSync, copyFileSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const here = new URL("..", import.meta.url).pathname;
const folder = mkdtempSync(join(tmpdir(), "mach-relay-"));
copyFileSync(join(here, "worker.js"), join(folder, "worker.js"));
writeFileSync(join(folder, "wrangler.toml"), readFileSync(join(here, "wrangler.toml"), "utf8").replace("REPLACE_WITH_YOUR_KV_NAMESPACE_ID", "local"));
writeFileSync(join(folder, ".dev.vars"), "RELAY_SECRET=local-secret\nAPNS_KEY=none\nAPNS_KEY_ID=none\nAPNS_TEAM_ID=none\n");
const port = 8790 + Math.floor(Math.random() * 100);
const server = Bun.spawn(["bunx", "wrangler", "dev", "--local", "--port", String(port), "--ip", "127.0.0.1"], { cwd: folder, stdout: "pipe", stderr: "pipe", env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" } });
const base = `http://127.0.0.1:${port}`;
let failed = false;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ` (${detail})` : ""}`);
  if (!ok) failed = true;
};
try {
  const begun = Date.now();
  let up = false;
  while (Date.now() - begun < 120000) {
    try {
      if ((await fetch(base + "/")).status === 200) {
        up = true;
        break;
      }
    } catch {}
    await Bun.sleep(300);
  }
  check("starts in Cloudflare's runtime", up, `${Date.now() - begun} ms including wrangler's own start`);
  if (!up) throw new Error("did not start");
  check("register without the secret is refused", (await fetch(base + "/register", { method: "POST", body: "{}" })).status === 403);
  check("a notification with the wrong secret is refused", (await fetch(base + "/pubsub/wrong", { method: "POST", body: "{}" })).status === 403);

  const heard = [];
  const socket = new WebSocket(`ws://127.0.0.1:${port}/live?emails=someone@example.com`, { headers: { "X-Mach-Secret": "local-secret" } });
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error("the app connection was refused"));
  });
  socket.onmessage = (event) => heard.push(String(event.data));
  socket.send("ping");
  await Bun.sleep(500);
  check("ping is answered with pong", heard.includes("pong"));

  const notify = () => fetch(`${base}/pubsub/local-secret`, { method: "POST", body: JSON.stringify({ message: { data: btoa(JSON.stringify({ emailAddress: "Someone@Example.com", historyId: 12345 })) } }) });
  const times = [];
  for (let i = 0; i < 20; i++) {
    const before = heard.length;
    const start = performance.now();
    const response = await notify();
    const acknowledged = performance.now() - start;
    while (heard.length === before && performance.now() - start < 3000) await Bun.sleep(1);
    times.push({ acknowledged, told: performance.now() - start, status: response.status });
  }
  const told = heard.filter((text) => text.startsWith("{")).map((text) => JSON.parse(text));
  check("a notification is acknowledged with 204", times.every((item) => item.status === 204));
  check("the connected app is told, for its own address", told.length === 20 && told.every((item) => item.email === "someone@example.com" && typeof item.at === "number"), `${told.length} of 20`);
  const middle = (key) => times.map((item) => item[key]).sort((a, b) => a - b)[10].toFixed(1);
  console.log(`     acknowledged in ${middle("acknowledged")} ms, app told in ${middle("told")} ms (median of 20, all on this machine)`);
  socket.close();
} catch (error) {
  check(String(error.message || error), false);
} finally {
  server.kill();
  await server.exited;
  rmSync(folder, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
