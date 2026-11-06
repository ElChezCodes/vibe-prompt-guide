import { useCallback, useEffect, useState } from "react";
import { getArenaNextUp, NextUpSong } from "@/integrations/supabase/proposals";

const POLL_MS = 5_000;

// Display-only (step 17): the order changes with new winners, proposals and
// who is present, so it is polled; the backend decides it.
export function useArenaNextUp(arenaId: string | undefined, enabled = true) {
  const [songs, setSongs] = useState<NextUpSong[]>([]);

  const refresh = useCallback(async () => {
    if (!arenaId) return;
    try {
      setSongs(await getArenaNextUp(arenaId));
    } catch {
      // The next poll tries again
    }
  }, [arenaId]);

  useEffect(() => {
    if (!arenaId || !enabled) return;
    refresh();
    const interval = window.setInterval(refresh, POLL_MS);
    return () => window.clearInterval(interval);
  }, [arenaId, enabled, refresh]);

  return { songs, refresh };
}
