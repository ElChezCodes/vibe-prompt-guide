import { useEffect, useRef, useState } from "react";
import { getMyPi, MyPi, PiAward } from "@/integrations/supabase/pi";

const POLL_MS = 20_000;
const NOTICE_MS = 6_000;

// Display-only "Your PI" (step 15): awards are written by the backend when a
// battle is created/completed, so re-read when refreshKey changes (battle id
// + state) and poll as a fallback. Awards newer than the first load become a
// short-lived notice.
export function useMyPi(arenaId: string | undefined, refreshKey?: unknown) {
  const [pi, setPi] = useState<MyPi | null>(null);
  const [notice, setNotice] = useState<PiAward[]>([]);
  const lastSeenId = useRef<number | null>(null);

  useEffect(() => {
    lastSeenId.current = null;
    setPi(null);
    setNotice([]);
  }, [arenaId]);

  useEffect(() => {
    if (!arenaId) return;
    let cancelled = false;
    const load = () =>
      getMyPi(arenaId).then((data) => {
        if (cancelled || !data) return;
        setPi(data);
        const newest = data.recent[0]?.id ?? 0;
        if (lastSeenId.current !== null) {
          const fresh = data.recent.filter((a) => a.id > lastSeenId.current);
          if (fresh.length) setNotice(fresh);
        }
        lastSeenId.current = Math.max(lastSeenId.current ?? 0, newest);
      });
    load();
    const interval = window.setInterval(load, POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [arenaId, refreshKey]);

  useEffect(() => {
    if (!notice.length) return;
    const timeout = window.setTimeout(() => setNotice([]), NOTICE_MS);
    return () => window.clearTimeout(timeout);
  }, [notice]);

  return { pi, notice };
}
