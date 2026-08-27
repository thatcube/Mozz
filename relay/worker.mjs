const CHANNEL = /^[A-Za-z0-9_-]{16,64}$/;
const DEFAULT_LIFETIME_SECONDS = 90 * 24 * 60 * 60;
const AUTHORIZE_URL =
  "https://api.backblazeb2.com/b2api/v4/b2_authorize_account";

export function createWorker(fetchImpl = fetch) {
  const state = { masterAuthorization: undefined };
  return {
    async fetch(request, env) {
      try {
        return await route(request, env, fetchImpl, state);
      } catch (error) {
        // B2 response bodies can contain account details. The client gets a
        // stable failure code; operational logs get only the error class.
        console.error("relay control-plane failure", error?.name ?? "Error");
        return json({ error: "provisioning_failed" }, 502);
      }
    },
  };
}

export default createWorker();

async function route(request, env, fetchImpl, state) {
  const url = new URL(request.url);
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  if (url.pathname === "/v1/channels") {
    const limited = await rateLimit(request, env);
    if (limited) return limited;
    const body = await parseJSON(request);
    const channelId = body?.channelId;
    if (!CHANNEL.test(channelId ?? "")) {
      return json({ error: "invalid_channel_id" }, 400);
    }
    return json(await mint(channelId, env, fetchImpl, state), 201);
  }

  const match = url.pathname.match(
    /^\/v1\/channels\/([A-Za-z0-9_-]{16,64})\/renew$/,
  );
  if (match) {
    const limited = await rateLimit(request, env);
    if (limited) return limited;
    const channelId = match[1];
    const current = parseBasic(request.headers.get("Authorization"));
    if (!current) return json({ error: "current_key_required" }, 401);
    const allowed = await authorizeChild(
      current.keyID,
      current.applicationKey,
      fetchImpl,
    );
    const storage = allowed.apiInfo?.storageApi;
    const expectedPrefix = `c/${channelId}/`;
    const bucket = storage?.allowed?.buckets?.find(
      (candidate) => candidate.id === env.B2_BUCKET_ID,
    );
    if (!bucket || storage.allowed.namePrefix !== expectedPrefix) {
      return json({ error: "wrong_channel_key" }, 403);
    }
    return json(await mint(channelId, env, fetchImpl, state), 200);
  }

  return json({ error: "not_found" }, 404);
}

async function mint(channelId, env, fetchImpl, state) {
  requireEnvironment(env);
  const authorization = await authorizeMaster(env, fetchImpl, state);
  const seconds = boundedLifetime(env.KEY_LIFETIME_SECONDS);
  const now = Date.now();
  const result = await b2(
    `${authorization.apiInfo.storageApi.apiUrl}/b2api/v4/b2_create_key`,
    authorization.authorizationToken,
    {
      accountId: env.B2_ACCOUNT_ID,
      capabilities: ["listFiles", "readFiles", "writeFiles"],
      keyName: `mozz-${channelId.slice(0, 20)}-${now}`,
      validDurationInSeconds: seconds,
      bucketIds: [env.B2_BUCKET_ID],
      namePrefix: `c/${channelId}/`,
    },
    fetchImpl,
  );
  if (!result.applicationKeyId || !result.applicationKey) {
    throw new Error("B2 returned no child key");
  }
  return {
    keyID: result.applicationKeyId,
    applicationKey: result.applicationKey,
    bucketName: env.B2_BUCKET_NAME,
    readEndpoint: env.B2_READ_ENDPOINT,
    expiresAtMS: result.expirationTimestamp ?? now + seconds * 1000,
  };
}

async function authorizeMaster(env, fetchImpl, state) {
  if (state.masterAuthorization) return state.masterAuthorization;
  state.masterAuthorization = authorizeChild(
    env.B2_MASTER_KEY_ID,
    env.B2_MASTER_APPLICATION_KEY,
    fetchImpl,
  );
  try {
    return await state.masterAuthorization;
  } catch (error) {
    state.masterAuthorization = undefined;
    throw error;
  }
}

async function authorizeChild(keyID, applicationKey, fetchImpl) {
  const response = await fetchImpl(AUTHORIZE_URL, {
    method: "GET",
    headers: {
      Authorization: `Basic ${btoa(`${keyID}:${applicationKey}`)}`,
    },
  });
  if (!response.ok) throw new Error(`B2 authorize ${response.status}`);
  return response.json();
}

async function b2(url, token, body, fetchImpl) {
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      Authorization: token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`B2 operation ${response.status}`);
  return response.json();
}

async function rateLimit(request, env) {
  if (!env.CHANNEL_RATE_LIMITER) {
    if (env.ALLOW_UNLIMITED_DEV === "true") return null;
    return json({ error: "rate_limiter_unavailable" }, 503);
  }
  const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const result = await env.CHANNEL_RATE_LIMITER.limit({ key });
  return result.success
    ? null
    : json({ error: "rate_limited" }, 429);
}

async function parseJSON(request) {
  const type = request.headers.get("Content-Type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) return null;
  try {
    return await request.json();
  } catch {
    return null;
  }
}

function parseBasic(value) {
  if (!value?.startsWith("Basic ")) return null;
  try {
    const decoded = atob(value.slice(6));
    const separator = decoded.indexOf(":");
    if (separator <= 0) return null;
    return {
      keyID: decoded.slice(0, separator),
      applicationKey: decoded.slice(separator + 1),
    };
  } catch {
    return null;
  }
}

function boundedLifetime(value) {
  const parsed = Number.parseInt(value ?? "", 10);
  const seconds = Number.isFinite(parsed)
    ? parsed
    : DEFAULT_LIFETIME_SECONDS;
  return Math.min(
    Math.max(seconds, 24 * 60 * 60),
    999 * 24 * 60 * 60,
  );
}

function requireEnvironment(env) {
  for (const key of [
    "B2_MASTER_KEY_ID",
    "B2_MASTER_APPLICATION_KEY",
    "B2_ACCOUNT_ID",
    "B2_BUCKET_ID",
    "B2_BUCKET_NAME",
    "B2_READ_ENDPOINT",
  ]) {
    if (!env[key]) throw new Error(`missing ${key}`);
  }
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "https://mozzmusic.com",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
  };
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...corsHeaders(),
    },
  });
}
