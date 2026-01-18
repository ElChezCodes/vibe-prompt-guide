import { useState, useCallback, useEffect, useRef } from "react";
import { supabase } from "@/integrations/supabase/client";

/**
 * Backend-authoritative battle closure state.
 * All fields are derived EXCLUSIVELY from the battles table.
 * The frontend NEVER computes vote counts, winners, or ties.
 */
export interface ClosureStateSnapshot {
  battleId: string | null;
  // Lock-in state - derived from battles.lockin_at
  isLockinReached: boolean;
  // Sudden death - derived from battles.sudden_death_active
  suddenDeathActive: boolean;
  // Resolution - derived from battles.state === 'completed'
  resolved: boolean;
  // Winner - derived from battles.winner_song_id
  winnerId: string | null;
  winnerSide: "A" | "B" | null;
  // Draw state - derived from winner_song_id === null when resolved
  isDraw: boolean;
  // MVP placeholder - always false
  bothSongsWin: boolean;
  // Timing - derived from battles table
  battleStartAt: string | null;
  battleEndAt: string | null;
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
  battleEndAt: null,
  lockinAt: null,
};

/**
 * Derives a pure snapshot from the battles table.
 * NO local vote counting. NO local resolution logic.
 * The backend is the SINGLE source of truth.
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
      ended_at,
      lockin_at,
      sudden_death_active,
      winner_song_id
    `,
    )
    .eq("id", battleId)
    .single();

  if (error || !battle) {
    console.error("[ClosureOrchestrator] Failed to fetch battle:", error);
    return { ...initialState, battleId };
  }

  const resolved = battle.state === "completed";
  const isDraw = resolved && battle.winner_song_id === null;

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
    isLockinReached: battle.lockin_at !== null,
    suddenDeathActive: battle.sudden_death_active ?? false,
    resolved,
    winnerId: battle.winner_song_id,
    winnerSide,
    isDraw,
    bothSongsWin: false, // MVP placeholder
    battleStartAt: battle.started_at,
    battleEndAt: battle.ended_at,
    lockinAt: battle.lockin_at,
  };
}

/**
 * Backend-authoritative battle closure hook.
 *
 * This hook is a PURE OBSERVER of backend state.
 * It NEVER:
 * - Computes vote counts
 * - Determines winners
 * - Detects ties
 * - Activates sudden death
 * - Ends battles based on timers
 *
 * All resolution logic is handled by backend functions:
 * - resolve_lockin_and_activate_sd(battle_id)
 * - resolve_battle_after_sudden_death(battle_id)
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

  // Listen for backend-driven events and refresh state
  useEffect(() => {
    const handleBattleClosed = (event: CustomEvent) => {
      const { battleId } = event.detail;
      if (battleId === battleIdRef.current) {
        refreshState();
      }
    };

    const handleLockinReachedEvent = (event: CustomEvent) => {
      const { battleId } = event.detail;
      if (battleId === battleIdRef.current) {
        refreshState();
      }
    };

    const handleSuddenDeathStarted = (event: CustomEvent) => {
      const { battleId } = event.detail;
      if (battleId === battleIdRef.current) {
        refreshState();
      }
    };

    window.addEventListener("battle:closed", handleBattleClosed as EventListener);
    window.addEventListener("battle:lockin_reached", handleLockinReachedEvent as EventListener);
    window.addEventListener("battle:sudden_death_started", handleSuddenDeathStarted as EventListener);

    return () => {
      window.removeEventListener("battle:closed", handleBattleClosed as EventListener);
      window.removeEventListener("battle:lockin_reached", handleLockinReachedEvent as EventListener);
      window.removeEventListener("battle:sudden_death_started", handleSuddenDeathStarted as EventListener);
    };
  }, [refreshState]);

  return {
    state,
    syncFromBattle,
    reset,
    refreshState,
  };
}
