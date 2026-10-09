// `cd Relay && bun test`: the relay must send exactly the Apple pushes, app messages and HTTP answers it sent
// before any performance work, and end up holding the same account records. No network, no real accounts.
import { expect, test } from "bun:test";
import golden from "./golden.json";
import { play } from "./scenarios.js";

const now = await play(new URL("../worker.js", import.meta.url).pathname);

for (const name of Object.keys(golden)) {
  test(name, () => {
    expect(now[name]).toEqual(golden[name]);
  });
}

test("every situation has a golden answer", () => {
  expect(Object.keys(now).sort()).toEqual(Object.keys(golden).sort());
});
