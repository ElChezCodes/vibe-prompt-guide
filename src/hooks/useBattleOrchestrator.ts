import { useState, useRef, useCallback, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import type { RealtimeChannel } from "@supabase/supabase-js";

export interface ArenaBattleView {
  battle_id: string;
  arena_id: string;
  state: "pending" | "active" | "closing" | "completed";

  started_at: string | null;
  duration_ms: number;
  lockin_at: string | null;
  resolution_type: string | null;
  winner_song_id: string | null;

  battle_created_at: string;

  song_a_id: string;
  song_a_title: string;
  song_a_artist: string;
  song_a_source: string;
  song_a_spotify_track_id: string;
  song_a_duration_ms: number;

  song_b_id: string;
  song_b_title: string;
  song_b_artist: string;
  song_b_source: string;
  song_b_spotify_track_id: string;
  song_b_duration_ms: number;

  votes_a: number;
  votes_b: number;
}

interface OrchestratorState {
  battle: ArenaBattleView | null;
  isRunning: boolean;
}

interface UseBattleOrchestratorReturn {
  battle: ArenaBattleView | null;
  isRunning: boolean;
  initBattleLoop: (arenaId: string) => Promise<ArenaBattleView | null>;
  stopBattleLoop: () => void;
  getCurrentBattle: () => ArenaBattleView | null;
}

export const useBattleOrchestrator = (): UseBattleOrchestratorReturn => {
  const [state, setState] = useState<OrchestratorState>({
    battle: null,
    isRunning: false,
  });

  const channelRef = useRef<RealtimeChannel | null>(null);
  const arenaIdRef = useRef<string | null>(null);
  const voteIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Mergeable fields from realtime payload
  const MERGE_FIELDS = [
    "state",
    "started_at",
    "duration_ms",
    "lockin_at",
    "resolution_type",
    "winner_song_id",
  ] as const;

  const fetchLatestBattle = useCallback(async (arenaId: string): Promise<ArenaBattleView | null> => {
    const { data, error } = await supabase
      .from("arena_live_state")
      .select("*")
      .eq("arena_id", arenaId)
      .order("battle_created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) {
      console.error("[Orchestrator] Failed to fetch arena_live_state:", error);
      return null;
    }

    return data as ArenaBattleView | null;
  }, []);

  const fetchVoteCounts = useCallback(async (arenaId: string) => {
    const { data, error } = await supabase
      .from("arena_live_state")
      .select("battle_id, votes_a, votes_b")
      .eq("arena_id", arenaId)
      .order("battle_created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (error) {
      console.error("[Orchestrator] Failed to fetch vote counts:", error);
      return;
    }

    if (!data) return;

    setState((prev) => {
      if (!prev.battle || prev.battle.battle_id !== data.battle_id) return prev;
      if (prev.battle.votes_a === data.votes_a && prev.battle.votes_b === data.votes_b) return prev;
      return {
        ...prev,
        battle: { ...prev.battle, votes_a: data.votes_a, votes_b: data.votes_b },
      };
    });
  }, []);

  const clearVoteInterval = useCallback(() => {
    if (voteIntervalRef.current) {
      clearInterval(voteIntervalRef.current);
      voteIntervalRef.current = null;
    }
  }, []);

  const stopBattleLoop = useCallback(() => {
    if (channelRef.current) {
      supabase.removeChannel(channelRef.current);
      channelRef.current = null;
    }
    clearVoteInterval();
    setState((prev) => ({ ...prev, isRunning: false }));
  }, [clearVoteInterval]);

  const initBattleLoop = useCallback(
    async (arenaId: string): Promise<ArenaBattleView | null> => {
      // Clean up any existing subscription & interval
      if (channelRef.current) {
        supabase.removeChannel(channelRef.current);
        channelRef.current = null;
      }
      clearVoteInterval();

      arenaIdRef.current = arenaId;
      setState((prev) => ({ ...prev, isRunning: true }));

      // Initial full fetch
      const battle = await fetchLatestBattle(arenaId);
      setState((prev) => ({ ...prev, battle }));

      // Subscribe to realtime changes on battles table filtered by arena_id
      const channel = supabase
        .channel(`battles:arena_id=eq.${arenaId}`)
        .on(
          "postgres_changes",
          {
            event: "*",
            schema: "public",
            table: "battles",
            filter: `arena_id=eq.${arenaId}`,
          },
          async (payload) => {
            if (arenaIdRef.current !== arenaId) return;

            const newRow = payload.new as Record<string, unknown> | undefined;
            const eventType = payload.eventType;

            // INSERT (new battle) → immediate render from payload, async backfill
            if (eventType === "INSERT" && newRow) {
              const newBattleId = newRow.id as string;

              // Build a minimal ArenaBattleView from the raw battles row,
              // preserving previous song metadata as placeholders until the
              // full view fetch completes.
              setState((prev) => {
                const prevBattle = prev.battle;
                const minimal: ArenaBattleView = {
                  battle_id: newBattleId,
                  arena_id: arenaId,
                  state: (newRow.state as ArenaBattleView["state"]) ?? "pending",
                  started_at: (newRow.started_at as string) ?? null,
                  duration_ms: (newRow.duration_ms as number) ?? 0,
                  lockin_at: (newRow.lockin_at as string) ?? null,
                  resolution_type: (newRow.resolution_type as string) ?? null,
                  winner_song_id: (newRow.winner_song_id as string) ?? null,
                  battle_created_at: (newRow.created_at as string) ?? new Date().toISOString(),
                  // Carry over previous song metadata as temporary placeholders
                  song_a_id: prevBattle?.song_a_id ?? "",
                  song_a_title: prevBattle?.song_a_title ?? "",
                  song_a_artist: prevBattle?.song_a_artist ?? "",
                  song_a_source: prevBattle?.song_a_source ?? "",
                  song_a_spotify_track_id: prevBattle?.song_a_spotify_track_id ?? "",
                  song_a_duration_ms: prevBattle?.song_a_duration_ms ?? 0,
                  song_b_id: prevBattle?.song_b_id ?? "",
                  song_b_title: prevBattle?.song_b_title ?? "",
                  song_b_artist: prevBattle?.song_b_artist ?? "",
                  song_b_source: prevBattle?.song_b_source ?? "",
                  song_b_spotify_track_id: prevBattle?.song_b_spotify_track_id ?? "",
                  song_b_duration_ms: prevBattle?.song_b_duration_ms ?? 0,
                  votes_a: 0,
                  votes_b: 0,
                };
                return { ...prev, battle: minimal };
              });

              // Non-blocking backfill with full view data (song metadata, etc.)
              fetchLatestBattle(arenaId).then((full) => {
                if (!full) return;
                setState((prev) => {
                  // Only replace if we're still on the same battle
                  if (prev.battle?.battle_id !== newBattleId) return prev;
                  return { ...prev, battle: full };
                });
              });

              return;
            }

            // UPDATE (same battle) → merge fields instantly
            if (eventType === "UPDATE" && newRow) {
              setState((prev) => {
                if (!prev.battle) return prev;
                if (prev.battle.battle_id !== newRow.id) return prev;

                const merged = { ...prev.battle };
                for (const field of MERGE_FIELDS) {
                  const dbField = field === "state" ? "state" : field;
                  if (dbField in newRow) {
                    (merged as Record<string, unknown>)[field] = newRow[dbField];
                  }
                }
                return { ...prev, battle: merged as ArenaBattleView };
              });
            }
          },
        )
        .subscribe();

      channelRef.current = channel;

      // Start periodic vote polling (every 2s)
      voteIntervalRef.current = setInterval(() => {
        if (arenaIdRef.current === arenaId) {
          fetchVoteCounts(arenaId);
        }
      }, 2000);

      return battle;
    },
    [fetchLatestBattle, fetchVoteCounts, clearVoteInterval],
  );

  const getCurrentBattle = useCallback((): ArenaBattleView | null => {
    return state.battle;
  }, [state.battle]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (channelRef.current) {
        supabase.removeChannel(channelRef.current);
        channelRef.current = null;
      }
      if (voteIntervalRef.current) {
        clearInterval(voteIntervalRef.current);
        voteIntervalRef.current = null;
      }
    };
  }, []);

  return {
    battle: state.battle,
    isRunning: state.isRunning,
    initBattleLoop,
    stopBattleLoop,
    getCurrentBattle,
  };
};
