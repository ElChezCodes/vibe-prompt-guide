import { useState, useRef, useCallback, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import type { RealtimeChannel } from "@supabase/supabase-js";

export interface ArenaBattleView {
  battle_id: string;
  arena_id: string;
  status: "pending" | "active" | "closing" | "completed";

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

  const stopBattleLoop = useCallback(() => {
    if (channelRef.current) {
      supabase.removeChannel(channelRef.current);
      channelRef.current = null;
    }
    setState((prev) => ({ ...prev, isRunning: false }));
  }, []);

  const initBattleLoop = useCallback(
    async (arenaId: string): Promise<ArenaBattleView | null> => {
      // Clean up any existing subscription
      if (channelRef.current) {
        supabase.removeChannel(channelRef.current);
        channelRef.current = null;
      }

      arenaIdRef.current = arenaId;
      setState((prev) => ({ ...prev, isRunning: true }));

      // Initial fetch
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
          async () => {
            if (arenaIdRef.current !== arenaId) return;
            const updated = await fetchLatestBattle(arenaId);
            setState((prev) => ({ ...prev, battle: updated }));
          },
        )
        .subscribe();

      channelRef.current = channel;

      return battle;
    },
    [fetchLatestBattle],
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
