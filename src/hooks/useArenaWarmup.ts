import { useEffect, useState } from "react";
import { ArenaWarmup, getArenaWarmup } from "@/integrations/supabase/arenas";

/**
 * Warm-up song of an arena (see supabase/sql/warmup_song_2026-10-26.sql and
 * spotify_playback_2026-10-27.sql), display only.
 *
 * Since step 6 the warm-up is the first track of the arena's Spotify playlist,
 * playing on the host's own device: Music Fighter plays no audio. start_arena_battles
 * sets warmup_started_at (shifted by resume_arena after a pause); from then on
 * battle 1 lasts the warm-up's duration.
 *
 * The "now playing" window is derived from the backend warmup_started_at --
 * it never gates votes or battle transitions.
 */
export function useArenaWarmup(arenaId: string | undefined, arenaState: string | undefined) {
  const [warmup, setWarmup] = useState<ArenaWarmup | null>(null);
  const [isPlayingWindow, setIsPlayingWindow] = useState(false);

  // Re-read on arena state changes (waiting -> active sets started_at)
  useEffect(() => {
    if (!arenaId) return;
    let cancelled = false;
    getArenaWarmup(arenaId)
      .then((row) => {
        if (!cancelled) setWarmup(row);
      })
      .catch(() => {
        if (!cancelled) setWarmup(null);
      });
    return () => {
      cancelled = true;
    };
  }, [arenaId, arenaState]);

  const startedAtMs = warmup?.started_at ? new Date(warmup.started_at).getTime() : null;
  const endsAtMs = startedAtMs !== null ? startedAtMs + warmup.duration_ms : null;

  useEffect(() => {
    if (endsAtMs === null || arenaState !== "active") {
      setIsPlayingWindow(false);
      return;
    }
    const remaining = endsAtMs - Date.now();
    setIsPlayingWindow(remaining > 0);
    if (remaining <= 0) return;
    const timeout = setTimeout(() => setIsPlayingWindow(false), remaining);
    return () => clearTimeout(timeout);
  }, [endsAtMs, arenaState]);

  return {
    warmup,
    isWarmupPlaying: isPlayingWindow,
  };
}
