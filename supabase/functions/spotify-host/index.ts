// Spotify/DB payloads are untyped JSON from outside services
/* eslint-disable @typescript-eslint/no-explicit-any */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * Host Spotify connection (roadmap step 5, supabase/sql/spotify_host_connection_2026-10-27.sql).
 *
 * The only place that sees Spotify tokens or the client secret. Actions
 * (POST { action, ... }, caller's Supabase JWT in Authorization):
 *   authorize      -> Spotify authorize URL (PKCE S256; verifier/state stay server-side)
 *   callback       -> exchanges code, stores encrypted tokens, probes Premium
 *   status         -> connection summary + live device list (refreshes the token if needed)
 *   select_device  -> transfers playback with play:false (nothing changes what plays) and
 *                     records the preferred device; also verifies Premium
 *   disconnect     -> deletes the tokens and every stored Spotify datum (Developer Policy I.1.2)
 *
 * Secrets: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_TOKEN_KEY (base64, 32 bytes),
 * optional SPOTIFY_REDIRECT_URIS (comma-separated allowlist).
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Minimum needed (Developer Policy I.1.1): devices/state, transfer/play (steps 6/18),
// the arena's private playlist (step 6). No public playlists, no profile data.
const SCOPES = ["user-read-playback-state", "user-modify-playback-state", "playlist-modify-private"];

const DEFAULT_REDIRECT_URIS = [
  "http://127.0.0.1:8080/spotify/callback",
  "https://creative-cue-codex.lovable.app/spotify/callback",
];

const TOKEN_KEY_VERSION = "v1";
const ACCOUNTS = "https://accounts.spotify.com";
const API = "https://api.spotify.com/v1";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

// ---------- encoding / crypto ----------

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const b64url = (bytes: Uint8Array) => b64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const randomB64url = (n: number) => b64url(crypto.getRandomValues(new Uint8Array(n)));

let tokenKey: Promise<CryptoKey> | null = null;
function getTokenKey() {
  if (!tokenKey) {
    const raw = unb64(Deno.env.get("SPOTIFY_TOKEN_KEY") ?? "");
    if (raw.length !== 32) throw new HttpError(500, "server_misconfigured", "SPOTIFY_TOKEN_KEY must be 32 bytes");
    tokenKey = crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  }
  return tokenKey;
}

// AAD binds each ciphertext to its owner and column, so rows/columns can't be swapped
async function encryptToken(plain: string, hostId: string, column: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(`${hostId}:${column}`) },
      await getTokenKey(),
      new TextEncoder().encode(plain),
    ),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv);
  out.set(ct, iv.length);
  return `${TOKEN_KEY_VERSION}:${b64(out)}`;
}

async function decryptToken(stored: string, hostId: string, column: string) {
  const [version, payload] = stored.split(":");
  if (version !== TOKEN_KEY_VERSION || !payload) throw new HttpError(500, "token_undecryptable");
  const bytes = unb64(payload);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.slice(0, 12), additionalData: new TextEncoder().encode(`${hostId}:${column}`) },
    await getTokenKey(),
    bytes.slice(12),
  );
  return new TextDecoder().decode(plain);
}

// ---------- Spotify helpers ----------

function clientCredentials() {
  const id = Deno.env.get("SPOTIFY_CLIENT_ID");
  const secret = Deno.env.get("SPOTIFY_CLIENT_SECRET");
  if (!id || !secret) throw new HttpError(500, "server_misconfigured", "Spotify client credentials missing");
  return { id, secret };
}

function allowedRedirectUris() {
  const env = Deno.env.get("SPOTIFY_REDIRECT_URIS");
  return env ? env.split(",").map((s) => s.trim()).filter(Boolean) : DEFAULT_REDIRECT_URIS;
}

// Only same-app relative paths, never another origin
function safeReturnTo(value: unknown) {
  return typeof value === "string" && value.startsWith("/") && !value.startsWith("//") ? value : "/";
}

async function tokenRequest(params: Record<string, string>) {
  const { id, secret } = clientCredentials();
  const res = await fetch(`${ACCOUNTS}/api/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: `Basic ${btoa(`${id}:${secret}`)}`,
    },
    body: new URLSearchParams(params),
  });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body };
}

async function spotifyApi(accessToken: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const text = await res.text();
  let body: any = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return { status: res.status, body };
}

// Player API: Free accounts get 403 with reason PREMIUM_REQUIRED
function premiumFromPlayerResponse(status: number, body: any): "premium" | "not_premium" | null {
  if (status >= 200 && status < 300) return "premium";
  if (status === 403 && body?.error?.reason === "PREMIUM_REQUIRED") return "not_premium";
  return null;
}

async function transferPlayback(accessToken: string, deviceId: string) {
  // play:false keeps the current playback state (paused stays paused)
  return spotifyApi(accessToken, "/me/player", {
    method: "PUT",
    body: JSON.stringify({ device_ids: [deviceId], play: false }),
  });
}

// ---------- account row ----------

async function loadAccount(userId: string) {
  const { data, error } = await admin
    .from("streaming_accounts")
    .select("*")
    .eq("host_id", userId)
    .eq("provider", "spotify")
    .maybeSingle();
  if (error) throw new HttpError(500, "db_error", error.message);
  return data;
}

async function deleteSpotifyData(userId: string) {
  await admin.from("streaming_accounts").delete().eq("host_id", userId);
  await admin.from("spotify_oauth_states").delete().eq("user_id", userId);
}

// Automatic backend refresh: any action needing the API refreshes 60 s before expiry.
// A revoked grant (user removed the app in Spotify) deletes the connection.
async function getAccessToken(account: any): Promise<string> {
  if (new Date(account.token_expires_at).getTime() - Date.now() > 60_000) {
    return decryptToken(account.access_token_enc, account.host_id, "access_token");
  }

  const refreshToken = await decryptToken(account.refresh_token_enc, account.host_id, "refresh_token");
  const { ok, body } = await tokenRequest({ grant_type: "refresh_token", refresh_token: refreshToken });
  if (!ok) {
    if (body?.error === "invalid_grant") {
      await deleteSpotifyData(account.host_id);
      throw new HttpError(401, "spotify_revoked", "Spotify access was revoked; connect again");
    }
    throw new HttpError(502, "spotify_refresh_failed", body?.error_description ?? body?.error);
  }

  const update: Record<string, unknown> = {
    access_token_enc: await encryptToken(body.access_token, account.host_id, "access_token"),
    token_expires_at: new Date(Date.now() + body.expires_in * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  };
  // Spotify may rotate the refresh token; keep the old one otherwise
  if (body.refresh_token) {
    update.refresh_token_enc = await encryptToken(body.refresh_token, account.host_id, "refresh_token");
  }
  if (body.scope) update.scopes = String(body.scope).split(" ").filter(Boolean);
  await admin.from("streaming_accounts").update(update).eq("id", account.id);
  return body.access_token;
}

async function setPremium(accountId: string, premium: "premium" | "not_premium" | null) {
  if (!premium) return;
  await admin
    .from("streaming_accounts")
    .update({ premium_status: premium, premium_checked_at: new Date().toISOString() })
    .eq("id", accountId);
}

// ---------- actions ----------

async function authorize(userId: string, body: any) {
  // Building the URL only needs the public client id; the secret is used at exchange time
  const id = Deno.env.get("SPOTIFY_CLIENT_ID");
  if (!id) throw new HttpError(500, "server_misconfigured", "SPOTIFY_CLIENT_ID missing");
  const redirectUri = String(body?.redirect_uri ?? "");
  if (!allowedRedirectUris().includes(redirectUri)) {
    throw new HttpError(400, "redirect_uri_not_allowed", `Not a registered redirect URI: ${redirectUri}`);
  }

  // Housekeeping: expired/abandoned attempts
  await admin.from("spotify_oauth_states").delete().lt("expires_at", new Date().toISOString());
  await admin.from("spotify_oauth_states").delete().eq("user_id", userId);

  const state = randomB64url(32);
  const verifier = randomB64url(64);
  const challenge = b64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));

  const { error } = await admin.from("spotify_oauth_states").insert({
    state,
    user_id: userId,
    code_verifier: verifier,
    redirect_uri: redirectUri,
    return_to: safeReturnTo(body?.return_to),
  });
  if (error) throw new HttpError(500, "db_error", error.message);

  const url = new URL(`${ACCOUNTS}/authorize`);
  url.search = new URLSearchParams({
    response_type: "code",
    client_id: id,
    scope: SCOPES.join(" "),
    redirect_uri: redirectUri,
    state,
    code_challenge_method: "S256",
    code_challenge: challenge,
    // Lets the host pick a different Spotify account on a shared browser
    show_dialog: "true",
  }).toString();
  return { url: url.toString() };
}

async function callback(userId: string, body: any) {
  const state = String(body?.state ?? "");
  // Single use: delete as we read; bound to the caller (CSRF / login swapping)
  const { data: row } = await admin
    .from("spotify_oauth_states")
    .delete()
    .eq("state", state)
    .eq("user_id", userId)
    .select()
    .maybeSingle();
  if (!row || new Date(row.expires_at).getTime() < Date.now()) {
    throw new HttpError(400, "invalid_state", "This Spotify sign-in link expired; try again");
  }
  const returnTo = row.return_to;

  if (body?.error) {
    // e.g. access_denied: the host cancelled on Spotify's screen
    return { connected: false, error: String(body.error), return_to: returnTo };
  }

  const token = await tokenRequest({
    grant_type: "authorization_code",
    code: String(body?.code ?? ""),
    redirect_uri: row.redirect_uri,
    code_verifier: row.code_verifier,
  });
  if (!token.ok) {
    throw new HttpError(502, "spotify_token_exchange_failed", token.body?.error_description ?? token.body?.error);
  }
  const t = token.body;

  const me = await spotifyApi(t.access_token, "/me");
  if (me.status !== 200 || !me.body?.id) {
    // Dev mode: a Spotify user not added in the dashboard's User Management gets 403 here
    throw new HttpError(403, "spotify_user_not_allowed", me.body?.error?.message ?? "Spotify rejected this account");
  }

  const record = {
    host_id: userId,
    provider: "spotify",
    provider_account_id: me.body.id,
    display_name: me.body.display_name ?? me.body.id,
    access_token_enc: await encryptToken(t.access_token, userId, "access_token"),
    refresh_token_enc: await encryptToken(t.refresh_token, userId, "refresh_token"),
    token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
    scopes: String(t.scope ?? "").split(" ").filter(Boolean),
    premium_status: "unverified",
    premium_checked_at: null,
    preferred_device_id: null,
    preferred_device_name: null,
    connected_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };
  const { data: saved, error } = await admin
    .from("streaming_accounts")
    .upsert(record, { onConflict: "host_id,provider" })
    .select("id")
    .single();
  if (error) throw new HttpError(500, "db_error", error.message);

  // Premium probe without changing anything: re-transfer to the device that is
  // already active, play:false. With no active device it stays "unverified"
  // until the host picks one.
  const player = await spotifyApi(t.access_token, "/me/player");
  const activeId = player.status === 200 ? player.body?.device?.id : null;
  if (activeId) {
    const probe = await transferPlayback(t.access_token, activeId);
    await setPremium(saved.id, premiumFromPlayerResponse(probe.status, probe.body));
  }

  return { connected: true, return_to: returnTo };
}

async function status(userId: string) {
  const account = await loadAccount(userId);
  if (!account) return { connected: false };

  const accessToken = await getAccessToken(account);
  const res = await spotifyApi(accessToken, "/me/player/devices");
  const devices = res.status === 200
    ? (res.body?.devices ?? []).map((d: any) => ({
        id: d.id,
        name: d.name,
        type: d.type,
        is_active: !!d.is_active,
        // Restricted devices can't be controlled through the Web API
        is_restricted: !!d.is_restricted,
      }))
    : [];

  return {
    connected: true,
    display_name: account.display_name,
    premium_status: account.premium_status,
    scopes: account.scopes,
    preferred_device_id: account.preferred_device_id,
    preferred_device_name: account.preferred_device_name,
    preferred_device_available: !!account.preferred_device_id &&
      devices.some((d: any) => d.id === account.preferred_device_id),
    devices,
    devices_error: res.status === 200 ? null : res.status,
  };
}

async function selectDevice(userId: string, body: any) {
  const account = await loadAccount(userId);
  if (!account) throw new HttpError(409, "not_connected");
  const deviceId = String(body?.device_id ?? "");
  const accessToken = await getAccessToken(account);

  const list = await spotifyApi(accessToken, "/me/player/devices");
  const device = (list.body?.devices ?? []).find((d: any) => d.id === deviceId);
  if (!device) throw new HttpError(404, "device_not_found", "That device is no longer available");
  if (device.is_restricted) throw new HttpError(409, "device_restricted", "Spotify doesn't allow controlling this device");

  const res = await transferPlayback(accessToken, deviceId);
  const premium = premiumFromPlayerResponse(res.status, res.body);
  await setPremium(account.id, premium);
  if (premium === "not_premium") return { ok: false, premium_status: "not_premium" };
  if (!premium) throw new HttpError(502, "transfer_failed", res.body?.error?.message ?? `Spotify answered ${res.status}`);

  await admin
    .from("streaming_accounts")
    .update({ preferred_device_id: device.id, preferred_device_name: device.name, updated_at: new Date().toISOString() })
    .eq("id", account.id);
  return { ok: true, premium_status: "premium" };
}

async function disconnect(userId: string) {
  // Spotify has no token-revocation endpoint: we delete everything we hold and
  // the UI points the host to spotify.com/account/apps to remove the app
  await deleteSpotifyData(userId);
  return { connected: false };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: auth, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !auth?.user) throw new HttpError(401, "unauthorized");
    const userId = auth.user.id;

    const body = await req.json().catch(() => ({}));
    switch (body?.action) {
      case "authorize":
        return json(await authorize(userId, body));
      case "callback":
        return json(await callback(userId, body));
      case "status":
        return json(await status(userId));
      case "select_device":
        return json(await selectDevice(userId, body));
      case "disconnect":
        return json(await disconnect(userId));
      default:
        throw new HttpError(400, "unknown_action");
    }
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.code, message: err.message }, err.status);
    console.error("[spotify-host]", err);
    return json({ error: "internal_error" }, 500);
  }
});
