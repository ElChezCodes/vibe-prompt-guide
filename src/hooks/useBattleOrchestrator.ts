import { useState, useRef, useCallback, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";

// Backend-authoritative battle states
type BattleState = "pending" | "active" | "closing" | "completed";

export interface BattleData {
  id: string;
  state: BattleState;
  song_a_id: string;
  song_b_id: string;
  started_at: string | null;
  duration_ms: number | null;
  lockin_at: string | null;
  sudden_death_active: boolean;
  winner_song_id: string | null;
}

interface OrchestratorState {
  battle: BattleData | null;
  isRunning: boolean;
}

interface UseBattleOrchestratorReturn {
  battle: BattleData | null;
  isRunning: boolean;
  initBattleLoop: (arenaId: string) => Promise<BattleData | null>;
  stopBattleLoop: () => void;
  getCurrentBattle: () => BattleData | null;
}

/**
 * Battle Orchestrator (Frontend)
 *
 * RESPONSIBILITY (MVP):
 * - Ensure there is a battle to observe
 * - Create pending battle if none exists
 * - Observe backend state changes
 *
 * DOES NOT:
 * - Start battles
 * - End battles
 * - Manage timers
 * - Change battle state
 */
export const useBattleOrchestrator = (): UseBattleOrchestratorReturn => {
  const [state, setState] = useState<OrchestratorState>({
    battle: null,
    isRunning: false,
  });

  const arenaIdRef = useRef<string | null>(null);
  const isStoppedRef = useRef(false);

  /**
   * MVP: create a pending battle if none exists
   */
  const createPendingBattle = useCallback(async (arenaId: string): Promise<BattleData | null> => {
    const MVP_SONG_A_ID = "11111111-1111-1111-1111-111111111111";
    const MVP_SONG_B_ID = "22222222-2222-2222-2222-222222222222";

    const { data, error } = await supabase
      .from("battles")
      .insert({
        arena_id: arenaId,
        song_a_id: MVP_SONG_A_ID,
        song_b_id: MVP_SONG_B_ID,
      })
      .select(
        "id, state, song_a_id, song_b_id, started_at, duration_ms, lockin_at, sudden_death_active, winner_song_id",
      )
      .single();

    if (error) {
      console.error("[BattleOrchestrator] Failed to create battle", error);
      return null;
    }

    return data as BattleData;
  }, []);

  /**
   * Initialize battle loop (bootstrap only)
   */
  const initBattleLoop = useCallback(
    async (arenaId: string): Promise<BattleData | null> => {
      arenaIdRef.current = arenaId;
      isStoppedRef.current = false;
      setState((prev) => ({ ...prev, isRunning: true }));

      // Look for existing battle (any non-completed)
      const { data, error } = await supabase
        .from("battles")
        .select(
          "id, state, song_a_id, song_b_id, started_at, duration_ms, lockin_at, sudden_death_active, winner_song_id",
        )
        .eq("arena_id", arenaId)
        .in("state", ["pending", "active", "closing"])
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();

      if (error) {
        console.error("[BattleOrchestrator] Failed to fetch battle", error);
      }

      let battle = data as BattleData | null;

      if (!battle) {
        battle = await createPendingBattle(arenaId);
      }

      if (battle) {
        setState((prev) => ({ ...prev, battle }));
      }

      return battle;
    },
    [createPendingBattle],
  );

  const stopBattleLoop = useCallback(() => {
    isStoppedRef.current = true;
    setState((prev) => ({ ...prev, isRunning: false }));
  }, []);

  const getCurrentBattle = useCallback(() => {
    return state.battle;
  }, [state.battle]);

  // Cleanup
  useEffect(() => {
    return () => {
      isStoppedRef.current = true;
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
