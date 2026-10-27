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

export async function startSpotifyConnect(returnTo: string): Promise<void> {
  // Same app, different origin = different anonymous session: don't hop over silently
  if (window.location.hostname === 'localhost') {
    throw new SpotifyHostError(
      'use_127_0_0_1',
      `Spotify only accepts 127.0.0.1: open http://127.0.0.1:${window.location.port || '8080'} instead of localhost`,
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
