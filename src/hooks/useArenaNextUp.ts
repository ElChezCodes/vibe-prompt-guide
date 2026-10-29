import { useEffect, useState } from "react";
import { getArenaNextUp, NextUpSong } from "@/integrations/supabase/proposals";

const POLL_MS = 5_000;

// Display-only (step 17): the order changes with new winners, proposals and
// who is present, so it is polled; the backend decides it.
export function useArenaNextUp(arenaId: string | undefined, enabled = true) {
  const [songs, setSongs] = useState<NextUpSong[]>([]);

  useEffect(() => {
    if (!arenaId || !enabled) return;
    let cancelled = false;
    const load = () =>
      getArenaNextUp(arenaId)
        .then((s) => {
          if (!cancelled) setSongs(s);
        })
        .catch(() => {});
    load();
    const interval = window.setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [arenaId, enabled]);

  return songs;
}
