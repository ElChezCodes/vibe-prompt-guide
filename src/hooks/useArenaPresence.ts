import { useEffect, useState } from "react";
import { ArenaPresence, getArenaPresence } from "@/integrations/supabase/presence";

const POLL_MS = 15_000;

// Display-only: the state changes with time (5-min window) rather than on a
// row write, so it is polled instead of subscribed. Change refreshKey to
// re-read right after an own action (e.g. a vote).
export function useArenaPresence(arenaId: string | undefined, enabled = true, refreshKey?: unknown) {
  const [presence, setPresence] = useState<ArenaPresence | null>(null);

  useEffect(() => {
    if (!arenaId || !enabled) return;
    let cancelled = false;
    const load = () =>
      getArenaPresence(arenaId).then((p) => {
        if (!cancelled) setPresence(p);
      });
    load();
    const interval = window.setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [arenaId, enabled, refreshKey]);

  return presence;
}
