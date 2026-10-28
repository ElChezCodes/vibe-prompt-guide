import { useEffect, useState } from "react";
import { ArenaQueueSummary, getArenaQueueSummary } from "@/integrations/supabase/proposals";

const POLL_MS = 15_000;

// Display-only (step 12b): human proposals still queued, and whether the
// arena is waiting for songs (no open battle). Polled like presence.
export function useArenaQueueSummary(arenaId: string | undefined, enabled = true) {
  const [summary, setSummary] = useState<ArenaQueueSummary | null>(null);

  useEffect(() => {
    if (!arenaId || !enabled) return;
    let cancelled = false;
    const load = () =>
      getArenaQueueSummary(arenaId)
        .then((s) => {
          if (!cancelled) setSummary(s);
        })
        .catch(() => {});
    load();
    const interval = window.setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [arenaId, enabled]);

  return summary;
}
