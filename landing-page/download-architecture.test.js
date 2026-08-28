import test from "node:test";
import assert from "node:assert/strict";
import {
  classifyArchitecture,
  detectMacArchitecture,
  downloadForArchitecture,
} from "./download-architecture.js";

test("classifies browser architecture hints", () => {
  assert.equal(classifyArchitecture("arm"), "arm64");
  assert.equal(classifyArchitecture("aarch64"), "arm64");
  assert.equal(classifyArchitecture("x86"), "intel");
  assert.equal(classifyArchitecture("x86_64"), "intel");
  assert.equal(classifyArchitecture(""), "unknown");
});

test("uses high-entropy hints on a Mac", async () => {
  const navigatorObject = {
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    userAgentData: {
      getHighEntropyValues: async () => ({ architecture: "arm", bitness: "64" }),
    },
  };
  assert.equal(await detectMacArchitecture(navigatorObject), "arm64");
});

test("does not infer architecture from Safari's ambiguous MacIntel platform", async () => {
  assert.equal(await detectMacArchitecture({ platform: "MacIntel" }), "unknown");
});

test("falls back to the compatible universal download", () => {
  assert.equal(downloadForArchitecture("arm64"), "/download/mac");
  assert.equal(downloadForArchitecture("intel"), "/download/mac-intel");
  assert.equal(downloadForArchitecture("unknown"), "/download/mac-intel");
});
