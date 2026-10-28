// Spotify/DB payloads are untyped JSON from outside services
/* eslint-disable @typescript-eslint/no-explicit-any */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  CatalogTrack,
  LIKED_SONGS_ID,
  PlaybackError,
  PlaybackStatus,
  SpotifyPlaybackProvider,
  trackUri,
} from "./playback.ts";

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
 *   disconnect     -> deletes the tokens and every stored Spotify datum (Developer Policy I.1.2),
 *                     incl. per-arena playlist/device ids, and pauses the host's running arenas
 *
 * Step 6 (supabase/sql/spotify_playback_2026-10-27.sql), through the Playback Provider:
 *   search         -> Spotify catalog search (max 10). In an arena it uses the arena host's
 *                     token (step 7: or the member's own, see below); otherwise the caller's own
 *   create_arena   -> creates an arena whose warm-up is a Spotify track
 *   propose        -> active proposal of a Spotify track (songs row + the caller's queues insert)
 *   start_arena    -> host: checks Premium + device, creates the private playlist with the
 *                     warm-up first, plays it on the device, then start_arena_battles
 *   resume_arena   -> host: plays the playlist again where it stopped and resumes the arena
 *   watch          -> pg_cron every 15 s (no user JWT): onProgress for every running arena;
 *                     pauses/resumes arenas (2 strikes, ~30 s)
 *
 * Step 7: a member's own Spotify, in any arena, only to pick songs to propose (never
 * for affinity/profiling, Developer Policy III.13; nothing of their library is stored):
 *   propose_sources -> what the caller can use: own connection, library scopes, host or not
 *   my_playlists    -> Liked Songs + their owned/collaborative playlists
 *   playlist_tracks -> one page (50) of one of those
 *   search/propose  -> account "own" (default: the caller's token, falling back to the
 *                      host's) or "host"
 *
 * Step 7b (supabase/sql/accounts_2026-10-27.sql): optional accounts. Lives here because
 * a merge must re-encrypt Spotify tokens (they are bound to the user id).
 *   merge_anonymous -> the account that just signed in claims the merge ticket its
 *                      anonymous session created: Spotify connection, arenas, votes and
 *                      proposals move to the account; the anonymous auth user is deleted
 *   delete_account  -> ends the arenas they host, deletes their Spotify data and auth user
 *
 * Secrets: SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, SPOTIFY_TOKEN_KEY (base64, 32 bytes),
 * optional SPOTIFY_REDIRECT_URIS (comma-separated allowlist), optional SPOTIFY_WATCH_SECRET.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Minimum needed (Developer Policy I.1.1): devices/state, transfer/play (steps 6/18),
// the arena's private playlist (step 6), the user's own playlists and Liked Songs to
// propose from (step 7). No public playlists, no profile data.
const LIBRARY_SCOPES = ["playlist-read-private", "user-library-read"];
const SCOPES = ["user-read-playback-state", "user-modify-playback-state", "playlist-modify-private", ...LIBRARY_SCOPES];

// Connections made before step 7 lack these: they keep working, the UI asks to reconnect
const canReadLibrary = (account: any) => LIBRARY_SCOPES.every((s) => (account?.scopes ?? []).includes(s));

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

// As the caller: RLS, auth.uid() and the presence/proposer triggers apply
function asUser(jwt: string) {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
}

// Watcher pacing: one check per arena per ~15 s cron tick, pause on the 2nd bad one
const WATCH_MIN_INTERVAL_MS = 12_000;
const STRIKES_TO_PAUSE = 2;
// Don't call the natural end of the playlist "paused"
const EXPECTED_TAIL_MS = 5_000;

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
  // Per-arena playlist/device ids too; their running arenas pause
  await admin.rpc("forget_host_spotify", { p_host_id: userId });
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

  // Reconnecting the same Spotify account (e.g. to grant the step-7 scopes) keeps
  // the chosen device and the Premium check
  const previous = await loadAccount(userId);
  const same = previous?.provider_account_id === me.body.id;

  const record = {
    host_id: userId,
    provider: "spotify",
    provider_account_id: me.body.id,
    display_name: me.body.display_name ?? me.body.id,
    access_token_enc: await encryptToken(t.access_token, userId, "access_token"),
    refresh_token_enc: await encryptToken(t.refresh_token, userId, "refresh_token"),
    token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
    scopes: String(t.scope ?? "").split(" ").filter(Boolean),
    premium_status: same ? previous.premium_status : "unverified",
    premium_checked_at: same ? previous.premium_checked_at : null,
    preferred_device_id: same ? previous.preferred_device_id : null,
    preferred_device_name: same ? previous.preferred_device_name : null,
    connected_at: same ? previous.connected_at : new Date().toISOString(),
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
    can_read_library: canReadLibrary(account),
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


// ---------- step 6: arenas on Spotify ----------

async function providerFor(account: any) {
  return new SpotifyPlaybackProvider(await getAccessToken(account));
}

// The device to play on: the one the host is already playing on (they moved
// playback to another device of theirs: follow it), else the chosen one
function pickDevice(status: PlaybackStatus, preferredId: string | null) {
  const usable = status.devices.filter((d) => !d.is_restricted);
  const active = usable.find((d) => d.id === status.activeDeviceId);
  if (active) return { device: active, adopted: active.id !== preferredId };
  const preferred = usable.find((d) => d.id === preferredId);
  return preferred ? { device: preferred, adopted: false } : null;
}

async function adoptDevice(account: any, device: { id: string; name: string }) {
  await admin
    .from("streaming_accounts")
    .update({ preferred_device_id: device.id, preferred_device_name: device.name, updated_at: new Date().toISOString() })
    .eq("id", account.id);
}

async function playbackError(err: unknown, accountId: string): Promise<never> {
  if (err instanceof PlaybackError && err.premiumRequired) {
    await setPremium(accountId, "not_premium");
    throw new HttpError(409, "spotify_not_premium", "Spotify Premium is required to play in an arena");
  }
  if (err instanceof PlaybackError && err.status === 404) {
    throw new HttpError(409, "no_device", "Open Spotify on your device and try again");
  }
  throw new HttpError(502, "play_failed", err instanceof Error ? err.message : String(err));
}

async function loadArena(arenaId: string) {
  const { data, error } = await admin
    .from("arenas")
    .select("id, name, state, host_id, warmup_song_id, warmup_started_at, paused_at, pause_reason")
    .eq("id", arenaId)
    .maybeSingle();
  if (error) throw new HttpError(500, "db_error", error.message);
  if (!data) throw new HttpError(404, "arena_not_found");
  return data;
}

// Host or participant (same rule as get_arena_warmup)
async function arenaForMember(userId: string, arenaId: string) {
  const arena = await loadArena(arenaId);
  if (arena.host_id === userId) return arena;
  const { data } = await admin
    .from("participants")
    .select("id")
    .eq("arena_id", arenaId)
    .eq("identity_anchor_id", userId)
    .maybeSingle();
  if (!data) throw new HttpError(403, "not_member");
  return arena;
}

async function hostProviderForArena(arena: any) {
  const account = arena.host_id ? await loadAccount(arena.host_id) : null;
  if (!account) throw new HttpError(409, "host_spotify_unavailable", "The host's Spotify isn't connected");
  return providerFor(account);
}

// The caller's own connection, or null if they have none / it was revoked
async function ownAccount(userId: string) {
  const account = await loadAccount(userId);
  if (!account) return null;
  try {
    return { account, provider: await providerFor(account) };
  } catch (err) {
    if (err instanceof HttpError && (err.code === "spotify_revoked" || err.code === "spotify_refresh_failed")) return null;
    throw err;
  }
}

// Arena catalog calls (step 7, user decision 2026-10-27): with account "own" a
// guest's own token is tried first and any Spotify failure (or no connection)
// silently falls back to the host's token (step 6); "host" goes straight there.
// For the host both are the same token.
async function withArenaCatalog<T>(
  userId: string,
  arena: any,
  account: unknown,
  fn: (provider: SpotifyPlaybackProvider) => Promise<T>,
): Promise<{ result: T; account: "own" | "host" }> {
  if (account !== "host" && arena.host_id !== userId) {
    const own = await ownAccount(userId);
    if (own) {
      try {
        return { result: await fn(own.provider), account: "own" };
      } catch (err) {
        if (!(err instanceof PlaybackError)) throw err;
        console.warn("[spotify-host] own token failed, using the host's", err.status, err.message);
      }
    }
  }
  const result = await fn(await hostProviderForArena(arena));
  return { result, account: arena.host_id === userId ? "own" : "host" };
}

async function search(userId: string, body: any) {
  const query = String(body?.query ?? "").trim().slice(0, 100);
  if (!query) return { tracks: [] };

  if (body?.arena_id) {
    const arena = await arenaForMember(userId, String(body.arena_id));
    const { result, account } = await withArenaCatalog(userId, arena, body?.account, (p) => p.search(query));
    return { tracks: result, account };
  }
  const account = await loadAccount(userId);
  if (!account) throw new HttpError(409, "spotify_not_connected", "Connect Spotify first");
  return { tracks: await (await providerFor(account)).search(query), account: "own" };
}

// A member of an arena that still takes proposals (same states as queues RLS)
async function arenaForProposing(userId: string, arenaId: string) {
  const arena = await arenaForMember(userId, arenaId);
  if (arena.state !== "waiting" && arena.state !== "active") throw new HttpError(409, "arena_closed");
  return arena;
}

async function proposeSources(userId: string, body: any) {
  const arena = await arenaForMember(userId, String(body?.arena_id ?? ""));
  const account = await loadAccount(userId);
  return {
    is_host: arena.host_id === userId,
    own_connected: !!account,
    can_read_library: canReadLibrary(account),
  };
}

// The caller's library only (their own token, never the host's); fetched live,
// shown back to them only and never stored (Developer Terms IV.3, V.4)
async function libraryProvider(userId: string) {
  const own = await ownAccount(userId);
  if (!own) throw new HttpError(409, "spotify_not_connected", "Connect your Spotify to use your playlists");
  if (!canReadLibrary(own.account)) {
    throw new HttpError(409, "needs_reconnect", "Reconnect Spotify to use your playlists");
  }
  return own;
}

async function myPlaylists(userId: string, body: any) {
  await arenaForProposing(userId, String(body?.arena_id ?? ""));
  const { account, provider } = await libraryProvider(userId);
  return { playlists: await provider.listPlaylists(account.provider_account_id) };
}

async function playlistTracks(userId: string, body: any) {
  await arenaForProposing(userId, String(body?.arena_id ?? ""));
  const playlistId = String(body?.playlist_id ?? "");
  if (playlistId !== LIKED_SONGS_ID && !/^[A-Za-z0-9]{10,40}$/.test(playlistId)) {
    throw new HttpError(400, "invalid_playlist");
  }
  const offset = Math.max(0, Math.min(100_000, Math.floor(Number(body?.offset) || 0)));
  const { provider } = await libraryProvider(userId);
  try {
    return await provider.playlistTracks(playlistId, offset);
  } catch (err) {
    // Only owned/collaborative playlists can be opened (Feb 2026)
    if (err instanceof PlaybackError && (err.status === 403 || err.status === 404)) {
      throw new HttpError(403, "playlist_not_readable", "Spotify doesn't let Music Fighter open this playlist");
    }
    throw err;
  }
}

async function getTrackOrFail(provider: SpotifyPlaybackProvider, trackId: unknown): Promise<CatalogTrack> {
  const track = await provider.getTrack(String(trackId ?? ""));
  if (!track) throw new HttpError(404, "track_not_found", "That Spotify track isn't available");
  return track;
}

async function createArena(userId: string, body: any) {
  const account = await loadAccount(userId);
  if (!account) throw new HttpError(409, "spotify_not_connected", "Connect Spotify before creating an arena");
  const track = await getTrackOrFail(await providerFor(account), body?.track_id);

  const name = String(body?.name ?? "").trim().slice(0, 80) || "Test Arena";
  const { data, error } = await admin.rpc("create_arena_spotify", {
    p_host_id: userId,
    p_name: name,
    p_mood: body?.mood ?? null,
    p_track: track,
  });
  if (error) throw new HttpError(400, "create_failed", error.message);
  return { arena_id: data };
}

async function propose(userId: string, jwt: string, body: any) {
  const arena = await arenaForMember(userId, String(body?.arena_id ?? ""));
  // Re-read from Spotify with the same account the caller picked it with
  const { result: track } = await withArenaCatalog(userId, arena, body?.account, async (p) => {
    const t = await p.getTrack(String(body?.track_id ?? ""));
    if (!t) throw new PlaybackError(404, null, "track not found with this account");
    return t;
  }).catch((err) => {
    if (err instanceof PlaybackError && err.status === 404) {
      throw new HttpError(404, "track_not_found", "That Spotify track isn't available");
    }
    throw err;
  });

  const { data: songId, error: songError } = await admin.rpc("upsert_spotify_song", {
    p_arena_id: arena.id,
    p_track: track,
  });
  if (songError) throw new HttpError(500, "db_error", songError.message);

  // As the caller: RLS (member, open arena), proposed_by stamp, presence touch
  const { error } = await asUser(jwt).from("queues").insert({
    arena_id: arena.id,
    song_id: songId,
    queue_type: "waiting",
    position: 0,
    priority: 1,
  });
  if (error) {
    // queues_arena_song_unique: someone already queued it
    if (error.code === "23505") return { result: "already_queued" };
    throw new HttpError(403, "propose_rejected", error.message);
  }
  return { result: "proposed" };
}

// ---------- step 7b: accounts ----------

// The anonymous side's Spotify connection moves to the account when the
// account has none, or when the anonymous side is hosting an open arena (its
// playlist lives in that Spotify account); otherwise the account's own wins.
async function moveSpotifyConnection(fromId: string, toId: string) {
  const from = await loadAccount(fromId);
  if (!from) return;
  const to = await loadAccount(toId);
  const { count } = await admin
    .from("arenas")
    .select("id", { count: "exact", head: true })
    .eq("host_id", fromId)
    .in("state", ["waiting", "active"]);
  if (!to || (count ?? 0) > 0) {
    const { id: _id, host_id: _host, ...rest } = from;
    const { error } = await admin.from("streaming_accounts").upsert(
      {
        ...rest,
        host_id: toId,
        access_token_enc: await encryptToken(await decryptToken(from.access_token_enc, fromId, "access_token"), toId, "access_token"),
        refresh_token_enc: await encryptToken(await decryptToken(from.refresh_token_enc, fromId, "refresh_token"), toId, "refresh_token"),
        updated_at: new Date().toISOString(),
      },
      { onConflict: "host_id,provider" },
    );
    if (error) throw new HttpError(500, "db_error", error.message);
  }
  await admin.from("streaming_accounts").delete().eq("host_id", fromId);
}

async function mergeAnonymous(user: any, body: any) {
  if (user.is_anonymous) throw new HttpError(403, "not_an_account", "Sign in first");
  const { data: ticket } = await admin
    .from("account_merge_tickets")
    .select("*")
    .eq("ticket", String(body?.ticket ?? ""))
    .maybeSingle();
  if (!ticket || new Date(ticket.expires_at).getTime() < Date.now()) {
    throw new HttpError(400, "invalid_ticket", "This sign-in took too long; your account is ready, but this device's activity wasn't merged");
  }
  const fromId = ticket.anon_user_id;
  const { data: from } = await admin.auth.admin.getUserById(fromId);
  if (!from?.user?.is_anonymous) throw new HttpError(409, "not_anonymous");

  await moveSpotifyConnection(fromId, user.id);
  const { data, error } = await admin.rpc("merge_anonymous_user", { p_from: fromId, p_to: user.id });
  if (error) throw new HttpError(500, "merge_failed", error.message);
  await admin.auth.admin.deleteUser(fromId);
  return { merged: true, ...data };
}

async function deleteAccount(user: any, jwt: string) {
  if (user.is_anonymous) throw new HttpError(400, "not_an_account");
  const { data: hosted } = await admin
    .from("arenas")
    .select("id")
    .eq("host_id", user.id)
    .in("state", ["waiting", "active"]);
  for (const arena of hosted ?? []) {
    const { error } = await asUser(jwt).rpc("end_arena", { p_arena_id: arena.id });
    if (error) throw new HttpError(409, "end_arena_failed", error.message);
  }
  await deleteSpotifyData(user.id);
  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) throw new HttpError(500, "delete_failed", error.message);
  return { deleted: true };
}

async function warmupTrackUri(arena: any) {
  const { data } = await admin
    .from("songs")
    .select("source, spotify_track_id, duration_ms")
    .eq("id", arena.warmup_song_id)
    .maybeSingle();
  if (!data || data.source !== "spotify") return null;
  return { uri: trackUri(data.spotify_track_id), durationMs: data.duration_ms as number };
}

function playlistDate(value: unknown) {
  if (typeof value === "string" && /^\d{2}\/\d{2}\/\d{2}$/.test(value)) return value;
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getUTCDate())}/${pad(d.getUTCMonth() + 1)}/${String(d.getUTCFullYear()).slice(2)}`;
}

async function startBattlesAsHost(jwt: string, arenaId: string) {
  const { data, error } = await asUser(jwt).rpc("start_arena_battles", { p_arena_id: arenaId });
  if (error) throw new HttpError(409, "start_failed", error.message);
  return data as string;
}

async function startArena(userId: string, jwt: string, body: any) {
  const arena = await loadArena(String(body?.arena_id ?? ""));
  if (arena.host_id !== userId) throw new HttpError(403, "not_host");
  // Re-entering a running arena: nothing to play, just the open battle
  if (arena.state === "active") return { battle_id: await startBattlesAsHost(jwt, arena.id) };
  if (arena.state !== "waiting") throw new HttpError(409, "arena_closed");

  const account = await loadAccount(userId);
  if (!account) throw new HttpError(409, "spotify_not_connected", "Connect Spotify to start");
  if (account.premium_status === "not_premium") {
    throw new HttpError(409, "spotify_not_premium", "Spotify Premium is required to play in an arena");
  }
  const warmup = await warmupTrackUri(arena);
  if (!warmup) {
    throw new HttpError(409, "warmup_not_spotify", "This arena's warm-up isn't a Spotify track; create a new arena");
  }

  const provider = await providerFor(account);
  const pick = pickDevice(await provider.getStatus(), account.preferred_device_id);
  if (!pick) throw new HttpError(409, "no_device", "Open Spotify on the device that will play and pick it");

  // A retried Start reuses the playlist it already created
  const { data: existing } = await admin.from("arena_playback").select("*").eq("arena_id", arena.id).maybeSingle();
  let session = existing?.playlist_id ? { id: existing.playlist_id, uri: existing.playlist_uri } : null;
  const sessionName = existing?.session_name ?? `Music Fighter · ${arena.name} · ${playlistDate(body?.local_date)}`;
  if (!session) {
    try {
      session = await provider.createSession(sessionName, warmup.uri);
    } catch (err) {
      throw new HttpError(502, "playlist_failed", err instanceof Error ? err.message : String(err));
    }
  }

  const { error: pbError } = await admin.from("arena_playback").upsert({
    arena_id: arena.id,
    host_id: userId,
    playlist_id: session.id,
    playlist_uri: session.uri,
    session_name: sessionName,
    device_id: pick.device.id,
    device_name: pick.device.name,
    strikes: 0,
    strike_reason: null,
    updated_at: new Date().toISOString(),
  });
  if (pbError) throw new HttpError(500, "db_error", pbError.message);

  try {
    await provider.play({ deviceId: pick.device.id, contextUri: session.uri });
  } catch (err) {
    await playbackError(err, account.id);
  }
  await setPremium(account.id, "premium");
  if (pick.adopted) await adoptDevice(account, pick.device);

  let battleId: string;
  try {
    battleId = await startBattlesAsHost(jwt, arena.id);
  } catch (err) {
    await provider.pause(pick.device.id);
    throw err;
  }

  // Music is expected until the warm-up ends (backend clock); step 18 extends it
  const { data: started } = await admin.from("arenas").select("warmup_started_at").eq("id", arena.id).single();
  const startedMs = new Date(started?.warmup_started_at ?? Date.now()).getTime();
  await admin
    .from("arena_playback")
    .update({
      expected_until: new Date(startedMs + warmup.durationMs - EXPECTED_TAIL_MS).toISOString(),
      is_playing: true,
      current_track_uri: warmup.uri,
      progress_ms: 0,
      resume_track_uri: warmup.uri,
      resume_position_ms: 0,
      checked_at: new Date().toISOString(),
    })
    .eq("arena_id", arena.id);

  return { battle_id: battleId };
}

// The arena playlist, recreated if a disconnect cleared it (step 6: the
// warm-up; step 18 must re-add the winners too)
async function ensureSession(provider: SpotifyPlaybackProvider, arena: any, pb: any) {
  if (pb.playlist_id) return { id: pb.playlist_id, uri: pb.playlist_uri };
  const warmup = await warmupTrackUri(arena);
  if (!warmup) return null;
  const session = await provider.createSession(pb.session_name ?? `Music Fighter · ${arena.name}`, warmup.uri);
  await admin
    .from("arena_playback")
    .update({ playlist_id: session.id, playlist_uri: session.uri, updated_at: new Date().toISOString() })
    .eq("arena_id", arena.id);
  return session;
}

async function playFromResumePoint(provider: SpotifyPlaybackProvider, session: any, deviceId: string, pb: any) {
  await provider.play({
    deviceId,
    contextUri: session.uri,
    offsetUri: pb.resume_track_uri ?? undefined,
    positionMs: pb.resume_position_ms ?? 0,
  });
}

// Was music expected at this moment (or when the arena paused)?
function musicExpected(pb: any, arena: any) {
  const at = arena.paused_at ? new Date(arena.paused_at).getTime() : Date.now();
  return !!pb.expected_until && new Date(pb.expected_until).getTime() > at;
}

// The battle clock follows the music: re-anchor battle 1 on when the warm-up
// really started on the host's player (sync_arena_clock, step-6 fix). Only the
// warm-up has a battle tied to it until step 18.
async function syncClock(arena: any, playingUri: string | null, progressMs: number | null) {
  if (!playingUri || progressMs == null) return;
  const warmup = await warmupTrackUri(arena);
  if (!warmup || warmup.uri !== playingUri) return;
  const { error } = await admin.rpc("sync_arena_clock", {
    p_arena_id: arena.id,
    p_track_started_at: new Date(Date.now() - progressMs).toISOString(),
  });
  if (error) console.warn("[spotify-host] sync_arena_clock", arena.id, error.message);
}

async function resumeArena(userId: string, body: any) {
  const arena = await loadArena(String(body?.arena_id ?? ""));
  if (arena.host_id !== userId) throw new HttpError(403, "not_host");
  if (arena.state !== "active" || !arena.paused_at) return { resumed: false };

  const account = await loadAccount(userId);
  if (!account) throw new HttpError(409, "spotify_not_connected", "Connect Spotify to resume");
  const { data: pb } = await admin.from("arena_playback").select("*").eq("arena_id", arena.id).maybeSingle();
  if (!pb) throw new HttpError(409, "no_playback");

  const provider = await providerFor(account);
  const pick = pickDevice(await provider.getStatus(), account.preferred_device_id);
  if (!pick) throw new HttpError(409, "no_device", "Open Spotify on your device and try again");

  if (musicExpected(pb, arena)) {
    const session = await ensureSession(provider, arena, pb);
    if (session) {
      try {
        await playFromResumePoint(provider, session, pick.device.id, pb);
      } catch (err) {
        await playbackError(err, account.id);
      }
    }
  }
  if (pick.adopted) await adoptDevice(account, pick.device);
  await admin.from("arena_playback").update({ device_id: pick.device.id, device_name: pick.device.name }).eq("arena_id", arena.id);
  await admin.rpc("resume_arena", { p_arena_id: arena.id });
  // Playback restarted at the resume point: the battle clock follows it
  if (musicExpected(pb, arena)) await syncClock(arena, pb.resume_track_uri, pb.resume_position_ms);
  return { resumed: true };
}

// onProgress for one arena: record what the host's player is doing and
// pause/resume the arena (user decisions 2026-10-27, see the SQL file)
async function checkArena(pb: any, arena: any) {
  const record = (fields: Record<string, unknown>) =>
    admin
      .from("arena_playback")
      .update({ ...fields, checked_at: new Date().toISOString(), updated_at: new Date().toISOString() })
      .eq("arena_id", pb.arena_id);

  let account: any = null;
  let provider: SpotifyPlaybackProvider | null = null;
  try {
    account = await loadAccount(pb.host_id);
    if (account) provider = await providerFor(account);
  } catch (err) {
    if (!(err instanceof HttpError && err.code === "spotify_revoked")) throw err;
    account = null;
  }
  if (!account || !provider || (!pb.playlist_id && !arena.paused_at)) {
    await admin.rpc("pause_arena", { p_arena_id: arena.id, p_reason: "spotify_disconnected" });
    await record({ is_playing: false });
    return;
  }

  await provider.onProgress(async (status) => {
    const pick = pickDevice(status, account.preferred_device_id);
    const onPlaylist = !!pb.playlist_uri && status.contextUri === pb.playlist_uri;
    const expected = musicExpected(pb, arena);
    const snapshot: Record<string, unknown> = {
      is_playing: status.isPlaying && onPlaylist,
      device_id: pick?.device.id ?? pb.device_id,
      device_name: pick?.device.name ?? pb.device_name,
    };
    if (onPlaylist && status.trackUri) {
      Object.assign(snapshot, {
        current_track_uri: status.trackUri,
        progress_ms: status.progressMs,
        resume_track_uri: status.trackUri,
        resume_position_ms: status.progressMs,
      });
    }
    if (pick?.adopted && expected) await adoptDevice(account, pick.device);

    if (arena.paused_at) {
      let canResume = false;
      // Where the music is after resuming: MF's resume point, or the host's player
      let resumedUri: string | null = null;
      let resumedMs: number | null = null;
      if (arena.pause_reason === "device_lost" || arena.pause_reason === "spotify_disconnected") {
        // The device (or the connection) is back: Music Fighter plays again
        if (pick) {
          canResume = true;
          if (expected) {
            try {
              const session = await ensureSession(provider!, arena, pb);
              if (session) {
                await playFromResumePoint(provider!, session, pick.device.id, pb);
                resumedUri = pb.resume_track_uri;
                resumedMs = pb.resume_position_ms;
              }
            } catch (err) {
              console.warn("[spotify-host] resume play failed", arena.id, err);
              canResume = false;
            }
          }
        }
      } else {
        // Host paused Spotify / played something else: back when they play the playlist
        canResume = !!pick && (!expected || (status.isPlaying && onPlaylist));
        if (canResume && expected) {
          resumedUri = status.trackUri;
          resumedMs = status.progressMs;
        }
      }
      await record(snapshot);
      if (canResume) {
        await admin.rpc("resume_arena", { p_arena_id: arena.id });
        await syncClock(arena, resumedUri, resumedMs);
      }
      return;
    }

    // Until step 18 music is only expected during the warm-up; outside that
    // window nothing audible depends on the device, so nothing pauses
    let problem: string | null = null;
    if (expected) {
      if (!pick) problem = "device_lost";
      else if (!status.isPlaying) problem = "playback_paused";
      else if (!onPlaylist) problem = "off_playlist";
    }
    const strikes = problem ? (problem === pb.strike_reason ? pb.strikes + 1 : 1) : 0;
    await record({ ...snapshot, strikes, strike_reason: problem });
    if (expected && !problem) await syncClock(arena, status.trackUri, status.progressMs);
    if (problem && strikes >= STRIKES_TO_PAUSE) {
      await admin.rpc("pause_arena", { p_arena_id: arena.id, p_reason: problem });
    }
  });
}

async function watch(req: Request) {
  const secret = Deno.env.get("SPOTIFY_WATCH_SECRET");
  if (secret && req.headers.get("x-watch-secret") !== secret) throw new HttpError(401, "unauthorized");

  const { data: rows, error } = await admin
    .from("arena_playback")
    .select("*, arenas!inner(id, name, state, host_id, warmup_song_id, paused_at, pause_reason)")
    .eq("arenas.state", "active");
  if (error) throw new HttpError(500, "db_error", error.message);

  let checked = 0;
  for (const row of rows ?? []) {
    // Extra calls change nothing: at most one check per arena per interval
    if (row.checked_at && Date.now() - new Date(row.checked_at).getTime() < WATCH_MIN_INTERVAL_MS) continue;
    try {
      await checkArena(row, row.arenas);
      checked++;
    } catch (err) {
      // Transient Spotify/network errors: next tick tries again
      console.error("[spotify-host] watch", row.arena_id, err);
    }
  }
  return { checked };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    // pg_cron, no user session
    if (body?.action === "watch") return json(await watch(req));

    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: auth, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !auth?.user) throw new HttpError(401, "unauthorized");
    const userId = auth.user.id;

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
      case "search":
        return json(await search(userId, body));
      case "create_arena":
        return json(await createArena(userId, body));
      case "propose":
        return json(await propose(userId, jwt, body));
      case "propose_sources":
        return json(await proposeSources(userId, body));
      case "my_playlists":
        return json(await myPlaylists(userId, body));
      case "playlist_tracks":
        return json(await playlistTracks(userId, body));
      case "merge_anonymous":
        return json(await mergeAnonymous(auth.user, body));
      case "delete_account":
        return json(await deleteAccount(auth.user, jwt));
      case "start_arena":
        return json(await startArena(userId, jwt, body));
      case "resume_arena":
        return json(await resumeArena(userId, body));
      default:
        throw new HttpError(400, "unknown_action");
    }
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.code, message: err.message }, err.status);
    console.error("[spotify-host]", err);
    // An unhandled Spotify API answer: say what Spotify said instead of a bare 500
    if (err instanceof PlaybackError) {
      return json({ error: "spotify_api_error", message: `Spotify ${err.status}: ${err.message}` }, 502);
    }
    return json({ error: "internal_error" }, 500);
  }
});
