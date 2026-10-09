// Writes golden.json from a given copy of the relay: `bun Relay/test/golden.js <path to worker.js>`.
// Run it against the relay as it was BEFORE a change; relay.test.js then holds the changed relay to it.
import { resolve } from "node:path";
import { play } from "./scenarios.js";

const path = resolve(process.argv[2] || new URL("../worker.js", import.meta.url).pathname);
const result = await play(path);
await Bun.write(new URL("./golden.json", import.meta.url).pathname, JSON.stringify(result, null, 1) + "\n");
const pushes = Object.values(result).reduce((sum, item) => sum + item.seen.filter((entry) => entry.kind === "apns").length, 0);
console.log(`${Object.keys(result).length} situations, ${pushes} Apple pushes written to golden.json`);
