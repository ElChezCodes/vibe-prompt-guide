import { useQuery, useQueryClient } from "@tanstack/react-query";
import { getCurrentArena } from "@/integrations/supabase/arenas";

const CURRENT_ARENA_KEY = ["current-arena"];

// Backend-owned (get_current_arena): drives the Arena/Proponer tabs and
// "Back to your arena". Refresh after joining, leaving or ending an arena.
export function useCurrentArena() {
  return useQuery({
    queryKey: CURRENT_ARENA_KEY,
    queryFn: getCurrentArena,
    staleTime: 0,
  });
}

export function useRefreshCurrentArena() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: CURRENT_ARENA_KEY });
}
