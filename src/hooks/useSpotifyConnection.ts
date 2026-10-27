import { useCallback, useEffect, useState } from "react";
import {
  disconnectSpotify,
  getSpotifyStatus,
  selectSpotifyDevice,
  SpotifyHostError,
  SpotifyStatus,
  startSpotifyConnect,
} from "@/integrations/supabase/spotify";

// Devices appear/disappear as the host opens Spotify elsewhere
const POLL_MS = 15_000;

/**
 * The host's Spotify connection as the backend sees it (display only). Every
 * action goes through the spotify-host Edge Function; nothing here holds a token.
 */
export function useSpotifyConnection() {
  const [status, setStatus] = useState<SpotifyStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      setStatus(await getSpotifyStatus());
      setError(null);
    } catch (err) {
      if (err instanceof SpotifyHostError && err.code === "spotify_revoked") {
        setStatus({ connected: false });
      }
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, POLL_MS);
    return () => clearInterval(interval);
  }, [refresh]);

  const run = useCallback(
    async (action: () => Promise<unknown>) => {
      setBusy(true);
      setError(null);
      try {
        await action();
        await refresh();
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(false);
      }
    },
    [refresh],
  );

  return {
    status,
    error,
    busy,
    refresh,
    // Leaves the page for Spotify; /spotify/callback brings the host back to returnTo
    connect: (returnTo: string) => run(() => startSpotifyConnect(returnTo)),
    selectDevice: (deviceId: string) => run(() => selectSpotifyDevice(deviceId)),
    disconnect: () => run(() => disconnectSpotify()),
  };
}
