import { supabase } from '@/integrations/supabase/client';

// Host Spotify connection (step 5). Tokens and the client secret live only in
// the `spotify-host` Edge Function; the frontend gets a summary and asks the
// function to act (see supabase/sql/spotify_host_connection_2026-10-27.sql).

export type PremiumStatus = 'unverified' | 'premium' | 'not_premium';

export interface SpotifyDevice {
  id: string;
  name: string;
  type: string;
  is_active: boolean;
  is_restricted: boolean;
}

export interface SpotifyStatus {
  connected: boolean;
  display_name?: string;
  premium_status?: PremiumStatus;
  preferred_device_id?: string | null;
  preferred_device_name?: string | null;
  preferred_device_available?: boolean;
  devices?: SpotifyDevice[];
  devices_error?: number | null;
}

// Stored summary only (no Spotify call): cheap, for Lobby/Create badges
export interface StreamingConnectionSummary {
  provider: string;
  display_name: string | null;
  premium_status: PremiumStatus;
  preferred_device_id: string | null;
  preferred_device_name: string | null;
  connected_at: string;
}

export class SpotifyHostError extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

async function callSpotifyHost<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke('spotify-host', { body });
  if (error) {
    // Non-2xx: the function's { error, message } is in the response body
    const context = (error as { context?: Response }).context;
    const payload = await context?.json?.().catch(() => null);
    throw new SpotifyHostError(payload?.error ?? 'request_failed', payload?.message ?? error.message);
  }
  return data as T;
}

// Spotify doesn't accept "localhost" redirects; the dev URI is registered on 127.0.0.1
export const spotifyRedirectUri = () => `${window.location.origin}/spotify/callback`;

export function isEmbedded(): boolean {
  try {
    return window.self !== window.top;
  } catch {
    return true;
  }
}

export async function startSpotifyConnect(returnTo: string): Promise<void> {
  // Same app, different origin = different anonymous session: don't hop over silently
  if (window.location.hostname === 'localhost') {
    throw new SpotifyHostError(
      'use_127_0_0_1',
      `Spotify only accepts 127.0.0.1: open http://127.0.0.1:${window.location.port || '8080'} instead of localhost`,
    );
  }
  // Spotify's login refuses to load inside an iframe (e.g. Lovable's editor
  // preview), and a new tab from there would have another anonymous session
  if (isEmbedded()) {
    throw new SpotifyHostError(
      'open_in_new_tab',
      'Spotify can\'t open inside this preview. Open the app in its own browser tab and connect from there.',
    );
  }
  const { url } = await callSpotifyHost<{ url: string }>({
    action: 'authorize',
    redirect_uri: spotifyRedirectUri(),
    return_to: returnTo,
  });
  window.location.assign(url);
}

export function completeSpotifyConnect(params: { code: string | null; state: string | null; error: string | null }) {
  return callSpotifyHost<{ connected: boolean; error?: string; return_to: string }>({ action: 'callback', ...params });
}

export const getSpotifyStatus = () => callSpotifyHost<SpotifyStatus>({ action: 'status' });

export const selectSpotifyDevice = (deviceId: string) =>
  callSpotifyHost<{ ok: boolean; premium_status: PremiumStatus }>({ action: 'select_device', device_id: deviceId });

export const disconnectSpotify = () => callSpotifyHost<{ connected: false }>({ action: 'disconnect' });

export async function getMyStreamingConnection(): Promise<StreamingConnectionSummary | null> {
  const { data, error } = await supabase.rpc('get_my_streaming_connection').maybeSingle();
  if (error) throw error;
  return (data as StreamingConnectionSummary) ?? null;
}

// ---------------------------------------------------------------------------
// Step 6: arenas on Spotify (supabase/sql/spotify_playback_2026-10-27.sql).
// The Playback Provider runs in spotify-host; this is how the app asks it.
// ---------------------------------------------------------------------------

export interface SpotifyTrack {
  spotify_track_id: string;
  title: string;
  artist: string;
  duration_ms: number;
  artwork_url: string | null;
  spotify_url: string;
}

// In an arena the arena host's token searches (guests never connect Spotify);
// without one (Create Arena) the caller's own
export async function searchSpotifyTracks(query: string, arenaId?: string): Promise<SpotifyTrack[]> {
  const { tracks } = await callSpotifyHost<{ tracks: SpotifyTrack[] }>({
    action: 'search',
    query,
    arena_id: arenaId ?? null,
  });
  return tracks ?? [];
}

// The function re-reads the track from Spotify: the client only sends its id
export async function createSpotifyArena(name: string, mood: string, trackId: string): Promise<string> {
  const { arena_id } = await callSpotifyHost<{ arena_id: string }>({
    action: 'create_arena',
    name,
    mood,
    track_id: trackId,
  });
  return arena_id;
}

export async function proposeSpotifyTrack(arenaId: string, trackId: string): Promise<'proposed' | 'already_queued'> {
  const { result } = await callSpotifyHost<{ result: 'proposed' | 'already_queued' }>({
    action: 'propose',
    arena_id: arenaId,
    track_id: trackId,
  });
  return result;
}

// Host: playlist + warm-up on the device, then waiting -> active (idempotent
// for a running arena). Errors carry a code: spotify_not_connected,
// spotify_not_premium, no_device, warmup_not_spotify, ...
export async function startSpotifyArena(arenaId: string): Promise<string> {
  const now = new Date();
  const pad = (n: number) => String(n).padStart(2, '0');
  const { battle_id } = await callSpotifyHost<{ battle_id: string }>({
    action: 'start_arena',
    arena_id: arenaId,
    // Playlist name date in the host's own time zone
    local_date: `${pad(now.getDate())}/${pad(now.getMonth() + 1)}/${String(now.getFullYear()).slice(2)}`,
  });
  return battle_id;
}

export const resumeSpotifyArena = (arenaId: string) =>
  callSpotifyHost<{ resumed: boolean }>({ action: 'resume_arena', arena_id: arenaId });

export type PauseReason = 'device_lost' | 'playback_paused' | 'off_playlist' | 'spotify_disconnected';

export interface ArenaPlayback {
  paused_at: string | null;
  pause_reason: PauseReason | null;
  is_playing: boolean;
  expected_until: string | null;
  checked_at: string | null;
  // Host only
  device_name: string | null;
  playlist_url: string | null;
}

export async function getArenaPlayback(arenaId: string): Promise<ArenaPlayback | null> {
  const { data, error } = await supabase.rpc('get_arena_playback', { p_arena_id: arenaId });
  if (error) throw error;
  return ((data ?? [])[0] as ArenaPlayback) ?? null;
}

export const PAUSE_REASON_LABELS: Record<PauseReason, string> = {
  device_lost: "The host's Spotify device is gone",
  playback_paused: 'Spotify was paused',
  off_playlist: "Spotify is playing something outside the arena's playlist",
  spotify_disconnected: "The host's Spotify is disconnected",
};
