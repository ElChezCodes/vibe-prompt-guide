import { useEffect, useState } from "react";
import { ArenaPlayback, getArenaPlayback } from "@/integrations/supabase/spotify";

// The watcher writes every ~15 s; a little faster here so a pause shows up quickly
const POLL_MS = 5_000;

/**
 * The arena's playback/pause state as the backend sees it (Playback Provider
 * onProgress, written by spotify-host "watch"). Display only: pausing and
 * resuming are decided server-side.
 */
export function useArenaPlayback(arenaId: string | undefined, enabled: boolean) {
  const [playback, setPlayback] = useState<ArenaPlayback | null>(null);

  useEffect(() => {
    if (!arenaId || !enabled) {
      setPlayback(null);
      return;
    }
    let cancelled = false;
    const load = () =>
      getArenaPlayback(arenaId)
        .then((row) => {
          if (!cancelled) setPlayback(row);
        })
        .catch(() => {});
    load();
    const interval = setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [arenaId, enabled]);

  return playback;
}
