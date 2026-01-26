import { useState, useRef, useCallback, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";

const MOCK_BATTLE_DURATION_SEC = 45;
const LOCK_IN_SEC = 15;

const BATTLE_DURATION_MS = MOCK_BATTLE_DURATION_SEC * 1000;

// Valid battle states (backend-authoritative)
type BattleState = "pending" | "active" | "closing" | "completed";

export interface BattleData {
  id: string;
  state: BattleState;
  song_a_id: string;
  song_b_id: string;
  started_at: string | null;
  duration_ms: number;
  // Backend-authoritative fields
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

export const useBattleOrchestrator = (): UseBattleOrchestratorReturn => {
  const [state, setState] = useState<OrchestratorState>({
    battle: null,
    isRunning: false,
  });

  const timerRef = useRef<NodeJS.Timeout | null>(null);
  const isTransitioningRef = useRef(false);
  const arenaIdRef = useRef<string | null>(null);
  const isStoppedRef = useRef(false);

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const startBattle = useCallback(async (battleId: string): Promise<BattleData | null> => {
    if (isTransitioningRef.current || isStoppedRef.current) return null;
    isTransitioningRef.current = true;

    const { error: updateError } = await supabase
      .from("battles")
      .update({
        state: "active",
        started_at: new Date().toISOString(),
        duration_ms: BATTLE_DURATION_MS,
      })
      .eq("id", battleId)
      .eq("state", "pending");

    if (updateError) {
      console.error("[Orchestrator] Failed to start battle:", updateError);
      isTransitioningRef.current = false;
      return null;
    }

    const { data: updatedBattle } = await supabase
      .from("battles")
      .select(
        "id, state, song_a_id, song_b_id, started_at, duration_ms, lockin_at, sudden_death_active, winner_song_id",
      )
      .eq("id", battleId)
      .maybeSingle();

    if (updatedBattle) {
      setState((prev) => ({ ...prev, battle: updatedBattle as BattleData }));
    }

    isTransitioningRef.current = false;
    return updatedBattle as BattleData | null;
  }, []);

  // DISABLED: Frontend is observer-only. Backend handles all battle finalization.
  const endBattle = useCallback(async (_battleId: string): Promise<BattleData | null> => null, []);

  const createPendingBattle = useCallback(async (arenaId: string): Promise<BattleData | null> => {
    // MVP mock song IDs - stable and intentional
    const MVP_SONG_A_ID = "11111111-1111-1111-1111-111111111111";
    const MVP_SONG_B_ID = "22222222-2222-2222-2222-222222222222";

    const { data: newBattle, error } = await supabase
      .from("battles")
      .insert({
        arena_id: arenaId,
        song_a_id: MVP_SONG_A_ID,
        song_b_id: MVP_SONG_B_ID,
        started_at: null,
      })
      .select(
        "id, state, song_a_id, song_b_id, started_at, duration_ms, lockin_at, sudden_death_active, winner_song_id",
      )
      .single();

    if (error) {
      console.error("[Orchestrator] Failed to create battle:", error);
      return null;
    }

    return newBattle as BattleData;
  }, []);

  // DISABLED: Frontend is observer-only. Backend handles all timing/scheduling.
  const scheduleEnd = useCallback(
    (_battleId: string, _continueLoop: (id: string) => void) => {},
    [],
  );

  // DISABLED: Frontend loop continuation removed. Backend drives battle transitions.
  const continueLoop = useCallback(
    async (_endingBattleId: string) => {},
    [],
  );

  const initBattleLoop = useCallback(
    async (arenaId: string): Promise<BattleData | null> => {
      arenaIdRef.current = arenaId;
      isStoppedRef.current = false;

      setState((prev) => ({ ...prev, isRunning: true }));

      // Check for existing pending/active battle
      const { data: existingBattle, error } = await supabase
        .from("battles")
        .select(
          "id, state, song_a_id, song_b_id, started_at, duration_ms, lockin_at, sudden_death_active, winner_song_id",
        )
        .eq("arena_id", arenaId)
        .in("state", ["pending", "active"])
        .maybeSingle();

      if (error) {
        console.error("[Orchestrator] Failed to fetch battle:", error);
      }

      let currentBattle = existingBattle as BattleData | null;

      // Create new pending battle if none exists
      if (!currentBattle) {
        currentBattle = await createPendingBattle(arenaId);
      }

      if (!currentBattle) {
        return null;
      }

      setState((prev) => ({ ...prev, battle: currentBattle }));

      // Start pending battle and schedule end
      if (currentBattle.state === "pending") {
        const started = await startBattle(currentBattle.id);
        if (started) {
          scheduleEnd(currentBattle.id, continueLoop);
          return started;
        }
      }

      // If already active, just return it (timer should be managed externally or resynced)
      return currentBattle;
    },
    [createPendingBattle, startBattle, scheduleEnd, continueLoop],
  );

  const stopBattleLoop = useCallback(() => {
    isStoppedRef.current = true;
    clearTimer();
    setState((prev) => ({ ...prev, isRunning: false }));
  }, [clearTimer]);

  const getCurrentBattle = useCallback((): BattleData | null => {
    return state.battle;
  }, [state.battle]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      clearTimer();
      isStoppedRef.current = true;
    };
  }, [clearTimer]);

  return {
    battle: state.battle,
    isRunning: state.isRunning,
    initBattleLoop,
    stopBattleLoop,
    getCurrentBattle,
  };
};
