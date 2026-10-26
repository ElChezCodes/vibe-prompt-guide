import { useState, useCallback, useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

/**
 * Backend-authoritative battle closure snapshot.
 * ALL fields are derived exclusively from the battles table.
 * The frontend NEVER computes votes, winners, or timing decisions.
 */

export interface ClosureStateSnapshot {
  battleId: string | null;

  // Derived from battles.state
  isLockinReached: boolean;
  suddenDeathActive: boolean;
  resolved: boolean;

  // Derived from battles.winner_song_id
  winnerId: string | null;
  winnerSide: "A" | "B" | null;
  isDraw: boolean;

  // MVP placeholder (future FASE 9)
  bothSongsWin: boolean;

  // Informational only
  battleStartAt: string | null;
  lockinAt: string | null;
}

export interface UseBattleClosureOrchestratorReturn {
  state: ClosureStateSnapshot;
  syncFromBattle: (battleId: string) => Promise<void>;
  reset: () => void;
  refreshState: () => Promise<void>;
}

const initialState: ClosureStateSnapshot = {
  battleId: null,
  isLockinReached: false,
  suddenDeathActive: false,
  resolved: false,
  winnerId: null,
  winnerSide: null,
  isDraw: false,
  bothSongsWin: false,
  battleStartAt: null,
  lockinAt: null,
};

/**
 * Fetches a backend-authoritative snapshot of battle closure state.
 * NO local logic. NO vote counting. NO timing assumptions.
 */
async function fetchBattleSnapshot(battleId: string): Promise<ClosureStateSnapshot> {
  const { data: battle, error } = await supabase
    .from("battles")
    .select(
      `
      id,
      state,
      song_a_id,
      song_b_id,
      started_at,
      lockin_at,
      sudden_death_active,
      winner_song_id,
      resolution_type
      `,
    )
    .eq("id", battleId)
    .single();

  if (error || !battle) {
    console.error("[ClosureOrchestrator] Failed to fetch battle", error);
    return { ...initialState, battleId };
  }

  const resolved = battle.state === "completed";
  const isLockinReached = battle.state === "closing";
  const suddenDeathActive = battle.state === "closing" && battle.sudden_death_active === true;

  // No winner also happens for resolution_type 'cancelled' (arena ended mid-battle)
  const isDraw = resolved && battle.resolution_type === "draw";

  let winnerSide: "A" | "B" | null = null;
  if (battle.winner_song_id) {
    if (battle.winner_song_id === battle.song_a_id) {
      winnerSide = "A";
    } else if (battle.winner_song_id === battle.song_b_id) {
      winnerSide = "B";
    }
  }

  return {
    battleId,
    isLockinReached,
    suddenDeathActive,
    resolved,
    winnerId: battle.winner_song_id,
    winnerSide,
    isDraw,
    bothSongsWin: false, // FASE 9
    battleStartAt: battle.started_at,
    lockinAt: battle.lockin_at,
  };
}

/**
 * Backend-authoritative battle closure hook.
 *
 * PURE OBSERVER:
 * - No timers
 * - No vote logic
 * - No resolution logic
 *
 * Reacts only to backend state changes.
 */
export function useBattleClosureOrchestrator(): UseBattleClosureOrchestratorReturn {
  const [state, setState] = useState<ClosureStateSnapshot>(initialState);

  const battleIdRef = useRef<string | null>(null);

  const refreshState = useCallback(async () => {
    if (!battleIdRef.current) {
      setState(initialState);
      return;
    }

    const snapshot = await fetchBattleSnapshot(battleIdRef.current);
    setState(snapshot);
  }, []);

  const syncFromBattle = useCallback(async (battleId: string) => {
    battleIdRef.current = battleId;
    const snapshot = await fetchBattleSnapshot(battleId);
    setState(snapshot);
  }, []);

  const reset = useCallback(() => {
    battleIdRef.current = null;
    setState(initialState);
  }, []);

  /**
   * Listen to backend-driven events and refresh snapshot.
   * Events are emitted by BattleClosureOrchestrator helpers.
   */
  useEffect(() => {
    const handleRefresh = (event: CustomEvent) => {
      const { battleId } = event.detail ?? {};
      if (battleId === battleIdRef.current) {
        refreshState();
      }
    };

    window.addEventListener("battle:closed", handleRefresh as EventListener);
    window.addEventListener("battle:lockin_reached", handleRefresh as EventListener);
    window.addEventListener("battle:sudden_death_started", handleRefresh as EventListener);

    return () => {
      window.removeEventListener("battle:closed", handleRefresh as EventListener);
      window.removeEventListener("battle:lockin_reached", handleRefresh as EventListener);
      window.removeEventListener("battle:sudden_death_started", handleRefresh as EventListener);
    };
  }, [refreshState]);

  return {
    state,
    syncFromBattle,
    reset,
    refreshState,
  };
}
