#!/usr/bin/env node
// Talk to a Verus node from Node.js.
//
//   node node.mjs
//
// No dependencies — fetch and node:child_process are enough. Requires Node 18+.
//
// Credentials are read from the node's data volume by default, so there is
// nothing to configure. Override with environment variables:
//
//   VERUS_RPC_URL, VERUS_RPC_USER, VERUS_RPC_PASSWORD, VERUS_CONTAINER

import { execFileSync } from "node:child_process";

const CONTAINER = process.env.VERUS_CONTAINER ?? "verus";
const RPC_URL = process.env.VERUS_RPC_URL ?? "http://127.0.0.1:18843";
const CREDS_PATH =
  process.env.VERUS_CREDS_PATH ?? "/home/verus/.komodo/vrsctest/rpc-credentials";

// ---------------------------------------------------------------------------
// Credentials
//
// The entrypoint generates a random user and password on first start and
// writes them into the data volume, so read them from there rather than
// hardcoding anything.
// ---------------------------------------------------------------------------

function loadCredentials() {
  const user = process.env.VERUS_RPC_USER;
  const password = process.env.VERUS_RPC_PASSWORD;
  if (user && password) return { user, password };

  let raw;
  try {
    raw = execFileSync("docker", ["exec", CONTAINER, "cat", CREDS_PATH], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    throw new Error(
      `Could not read credentials from container '${CONTAINER}'. ` +
        "Set VERUS_RPC_USER and VERUS_RPC_PASSWORD, or VERUS_CONTAINER.",
    );
  }

  const read = (key) => raw.match(new RegExp(`^${key}=(.*)$`, "m"))?.[1]?.trim();
  return { user: read("RPC_USER"), password: read("RPC_PASSWORD") };
}

// ---------------------------------------------------------------------------
// A minimal client. Verus speaks Bitcoin-style JSON-RPC 1.0 over HTTP basic auth.
// ---------------------------------------------------------------------------

class VerusClient {
  #auth;

  constructor(url, user, password) {
    this.url = url;
    this.#auth = "Basic " + Buffer.from(`${user}:${password}`).toString("base64");
  }

  async call(method, params = []) {
    const response = await fetch(this.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: this.#auth },
      body: JSON.stringify({ jsonrpc: "1.0", id: "node", method, params }),
    });

    // A non-2xx still carries a JSON body with the real reason, so read it
    // before deciding what to throw.
    const text = await response.text();
    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      throw new Error(`${method}: HTTP ${response.status}: ${text.slice(0, 200)}`);
    }
    if (payload.error) {
      throw new Error(`${method}: ${payload.error.message ?? JSON.stringify(payload.error)}`);
    }
    return payload.result;
  }
}

// ---------------------------------------------------------------------------

async function main() {
  const { user, password } = loadCredentials();
  const verus = new VerusClient(RPC_URL, user, password);

  const info = await verus.call("getinfo");
  console.log("== getinfo ==");
  console.log({
    version: info.VRSCversion,
    chain: info.name,
    blocks: info.blocks,
    connections: info.connections,
  });

  const chain = await verus.call("getblockchaininfo");
  console.log("\n== getblockchaininfo ==");
  console.log({
    blocks: chain.blocks,
    headers: chain.headers,
    progress: `${(chain.verificationprogress * 100).toFixed(2)}%`,
  });

  // getblockhash takes a height and returns the hash getblock wants.
  const height = await verus.call("getblockcount");
  const hash = await verus.call("getblockhash", [height]);
  const block = await verus.call("getblock", [hash]);

  console.log("\n== getblock (the current tip) ==");
  console.log({
    height: block.height,
    hash: block.hash,
    time: new Date(block.time * 1000).toISOString(),
    size: block.size,
    transactions: block.tx.length,
  });

  console.log(`\nNode is at block ${height}.`);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
