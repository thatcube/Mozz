import assert from "node:assert/strict";
import test from "node:test";
import { createWorker } from "./worker.mjs";

const channelId = "abcdefghijklmnop";

function environment(overrides = {}) {
  return {
    B2_MASTER_KEY_ID: "master-id",
    B2_MASTER_APPLICATION_KEY: "master-secret",
    B2_ACCOUNT_ID: "account-id",
    B2_BUCKET_ID: "bucket-id",
    B2_BUCKET_NAME: "mozz-relay",
    B2_READ_ENDPOINT: "https://f005.backblazeb2.com/file/mozz-relay",
    KEY_LIFETIME_SECONDS: "7776000",
    CHANNEL_RATE_LIMITER: {
      async limit() {
        return { success: true };
      },
    },
    ...overrides,
  };
}

function b2Fetch(calls, child = {}) {
  return async (url, init) => {
    calls.push({ url: String(url), init });
    if (String(url).endsWith("b2_authorize_account")) {
      return Response.json({
        authorizationToken: child.token ?? "master-token",
        apiInfo: {
          storageApi: {
            apiUrl: "https://api.example.test",
            allowed: child.allowed ?? {
              buckets: [{ id: "bucket-id", name: "mozz-relay" }],
              namePrefix: null,
            },
          },
        },
      });
    }
    if (String(url).endsWith("b2_create_key")) {
      return Response.json({
        applicationKeyId: "child-id",
        applicationKey: "child-secret",
        expirationTimestamp: 2_000_000_000_000,
      });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
}

test("mints one prefix-scoped least-privilege key", async () => {
  const calls = [];
  const worker = createWorker(b2Fetch(calls));
  const response = await worker.fetch(
    new Request("https://relay.test/v1/channels", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "CF-Connecting-IP": "192.0.2.1",
      },
      body: JSON.stringify({ channelId }),
    }),
    environment(),
  );

  assert.equal(response.status, 201);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  const result = await response.json();
  assert.deepEqual(result, {
    keyID: "child-id",
    applicationKey: "child-secret",
    bucketName: "mozz-relay",
    readEndpoint: "https://f005.backblazeb2.com/file/mozz-relay",
    expiresAtMS: 2_000_000_000_000,
  });

  const create = calls.find((call) => call.url.endsWith("b2_create_key"));
  const body = JSON.parse(create.init.body);
  assert.deepEqual(body.capabilities, [
    "listFiles",
    "readFiles",
    "writeFiles",
  ]);
  assert.deepEqual(body.bucketIds, ["bucket-id"]);
  assert.equal(body.namePrefix, `c/${channelId}/`);
  assert.equal(body.validDurationInSeconds, 7_776_000);
  assert.ok(!JSON.stringify(body).includes("master-secret"));
});

test("rejects an invalid channel before touching B2", async () => {
  const calls = [];
  const response = await createWorker(b2Fetch(calls)).fetch(
    new Request("https://relay.test/v1/channels", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ channelId: "../somewhere" }),
    }),
    environment(),
  );

  assert.equal(response.status, 400);
  assert.equal(calls.length, 0);
});

test("fails closed without rate limiting", async () => {
  const calls = [];
  const env = environment();
  delete env.CHANNEL_RATE_LIMITER;
  const response = await createWorker(b2Fetch(calls)).fetch(
    new Request("https://relay.test/v1/channels", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ channelId }),
    }),
    env,
  );

  assert.equal(response.status, 503);
  assert.equal(calls.length, 0);
});

test("rate limited callers cannot mint keys", async () => {
  const calls = [];
  const response = await createWorker(b2Fetch(calls)).fetch(
    new Request("https://relay.test/v1/channels", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ channelId }),
    }),
    environment({
      CHANNEL_RATE_LIMITER: {
        async limit() {
          return { success: false };
        },
      },
    }),
  );

  assert.equal(response.status, 429);
  assert.equal(calls.length, 0);
});

test("renewal proves the existing key belongs to this exact channel", async () => {
  const calls = [];
  const fetchImpl = b2Fetch(calls, {
    token: "child-token",
    allowed: {
      buckets: [{ id: "bucket-id", name: "mozz-relay" }],
      namePrefix: `c/${channelId}/`,
    },
  });
  const basic = Buffer.from("old-id:old-secret").toString("base64");
  const response = await createWorker(fetchImpl).fetch(
    new Request(`https://relay.test/v1/channels/${channelId}/renew`, {
      method: "POST",
      headers: { Authorization: `Basic ${basic}` },
    }),
    environment(),
  );

  assert.equal(response.status, 200);
  assert.ok(
    calls.some(
      (call) =>
        call.url.endsWith("b2_authorize_account") &&
        call.init.headers.Authorization === `Basic ${basic}`,
    ),
  );
});

test("a valid key for another prefix cannot renew this channel", async () => {
  const calls = [];
  const fetchImpl = b2Fetch(calls, {
    allowed: {
      buckets: [{ id: "bucket-id", name: "mozz-relay" }],
      namePrefix: "c/someone-else/",
    },
  });
  const response = await createWorker(fetchImpl).fetch(
    new Request(`https://relay.test/v1/channels/${channelId}/renew`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${Buffer.from("id:key").toString("base64")}`,
      },
    }),
    environment(),
  );

  assert.equal(response.status, 403);
  assert.equal(
    calls.filter((call) => call.url.endsWith("b2_create_key")).length,
    0,
  );
});

test("only mozzmusic.com receives browser CORS access", async () => {
  const response = await createWorker(b2Fetch([])).fetch(
    new Request("https://relay.test/v1/channels", { method: "OPTIONS" }),
    environment(),
  );

  assert.equal(
    response.headers.get("Access-Control-Allow-Origin"),
    "https://mozzmusic.com",
  );
});
