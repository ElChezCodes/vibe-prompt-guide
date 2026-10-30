import { useEffect, useState } from "react";
import { getStageView, StageViewData } from "@/integrations/supabase/stageView";

// Credits, now playing, next up, ranking: a few seconds late is fine (the
// battle itself comes from useBattleOrchestrator, realtime + 2 s)
const POLL_MS = 4_000;

export type StageViewStatus = "loading" | "ready" | "not_found";

export function useStageView(code: string) {
  const [data, setData] = useState<StageViewData | null>(null);
  const [status, setStatus] = useState<StageViewStatus>("loading");

  useEffect(() => {
    let cancelled = false;
    const load = () =>
      getStageView(code)
        .then((row) => {
          if (cancelled) return;
          setData(row);
          setStatus(row ? "ready" : "not_found");
        })
        // A failed poll keeps the last good data on screen
        .catch(() => {});
    load();
    const interval = setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [code]);

  return { data, status };
}
