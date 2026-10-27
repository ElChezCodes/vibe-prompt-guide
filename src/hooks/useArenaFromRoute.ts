import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { Arena, getArenaByCode } from "@/integrations/supabase/arenas";

type RouteArenaStatus = "loading" | "ready" | "not_found" | "error";

// Resolves /a/:code/... to the arena. Host-ness comes from arenas.host_id
// (the same check RLS enforces), never from router state.
export function useArenaFromRoute() {
  const { code = "" } = useParams();
  const [arena, setArena] = useState<Arena | null>(null);
  const [isHost, setIsHost] = useState(false);
  const [status, setStatus] = useState<RouteArenaStatus>("loading");

  useEffect(() => {
    let cancelled = false;
    setStatus("loading");

    const load = async () => {
      try {
        const [found, { data: { session } }] = await Promise.all([
          getArenaByCode(code),
          supabase.auth.getSession(),
        ]);
        if (cancelled) return;
        setArena(found);
        setIsHost(!!found && !!session?.user && found.host_id === session.user.id);
        setStatus(found ? "ready" : "not_found");
      } catch {
        if (!cancelled) setStatus("error");
      }
    };

    load();
    return () => {
      cancelled = true;
    };
  }, [code]);

  return { code, arena, setArena, isHost, status };
}
