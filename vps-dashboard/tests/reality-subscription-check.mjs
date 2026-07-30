import { VpsStatusStore } from "../src/worker.js";

class MemoryStorage {
  constructor() {
    this.values = new Map();
  }

  async get(key) {
    return this.values.get(key);
  }

  async put(key, value) {
    this.values.set(key, structuredClone(value));
  }

  async delete(key) {
    this.values.delete(key);
  }

  async list({ prefix }) {
    return new Map(
      [...this.values].filter(([key]) => key.startsWith(prefix)),
    );
  }
}

const storage = new MemoryStorage();
const store = new VpsStatusStore({ storage }, {});
const record = {
  node_id: "synthetic-reality",
  name: "Synthetic Reality",
  server: "reality.example.test",
  port: 443,
  uuid: "00000000-0000-4000-8000-000000000008",
  sni: "target.example.test",
  public_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  short_id: "0123456789abcdef",
  fingerprint: "chrome",
  transport: "xhttp",
  path: "/reality",
  host: "",
  mode: "auto",
  encryption: "none",
  updated_at: 1,
};

let response = await store.fetch(new Request("https://store/reality/upsert", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify(record),
}));
if (!response.ok) throw new Error(`upsert failed: ${response.status}`);

response = await store.fetch(new Request(
  "https://store/anytls/subscription?format=nekobox",
));
const yaml = await response.text();
for (const expected of [
  "type: vless",
  "network: xhttp",
  "encryption: none",
  "reality-opts:",
  "public-key: \"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"",
  "short-id: \"0123456789abcdef\"",
  "xhttp-opts:",
  "path: \"/reality\"",
]) {
  if (!yaml.includes(expected)) throw new Error(`YAML missing: ${expected}`);
}

response = await store.fetch(new Request(
  "https://store/anytls/subscription?format=uri",
));
const link = Buffer.from(await response.text(), "base64").toString("utf8");
for (const expected of [
  "security=reality",
  "encryption=none",
  "type=xhttp",
  "pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  "sid=0123456789abcdef",
  "path=%2Freality",
]) {
  if (!link.includes(expected)) throw new Error(`URI missing: ${expected}`);
}

console.log("REALITY_SUBSCRIPTION_OK");
