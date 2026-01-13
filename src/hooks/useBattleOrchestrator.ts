import { useState, useRef, useCallback, useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";

const MOCK_BATTLE_DURATION_SEC = 45;
const LOCK_IN_SEC = 15;
const PASSIVE_WINDOW_SEC = 30;

const BATTLE_DURATION_MS = MOCK_BATTLE_DURATION_SEC * 1000;

if (MOCK_BATTLE_DURATION_SEC < LOCK_IN_SEC + PASSIVE_WINDOW_SEC) {
  throw new Error("[BattleOrchestrator] Invalid mock duration: must be >= lock-in + passive window");
}

export interface BattleData {
  id: string;
  state: string;
  song_a_id: string;
  song_b_id: string;
  started_at: string | null;
  duration_ms: number;
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
        duration_ms: 45000,
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
      .select("id, state, song_a_id, song_b_id")
      .eq("id", battleId)
      .maybeSingle();

    if (updatedBattle) {
      setState((prev) => ({ ...prev, battle: updatedBattle }));
    }

    isTransitioningRef.current = false;
    return updatedBattle;
  }, []);

  const endBattle = useCallback(async (battleId: string): Promise<BattleData | null> => {
    if (isTransitioningRef.current || isStoppedRef.current) return null;
    isTransitioningRef.current = true;

    const { error: updateError } = await supabase
      .from("battles")
      .update({
        state: "finished",
        ended_at: new Date().toISOString(),
      })
      .eq("id", battleId)
      .eq("state", "active");

    if (updateError) {
      console.error("[Orchestrator] Failed to end battle:", updateError);
      isTransitioningRef.current = false;
      return null;
    }

    const { data: updatedBattle } = await supabase
      .from("battles")
      .select("id, state, song_a_id, song_b_id")
      .eq("id", battleId)
      .maybeSingle();

    if (updatedBattle) {
      setState((prev) => ({ ...prev, battle: updatedBattle }));
    }

    isTransitioningRef.current = false;
    return updatedBattle;
  }, []);

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
      .select("id, state, song_a_id, song_b_id")
      .single();

    if (error) {
      console.error("[Orchestrator] Failed to create battle:", error);
      return null;
    }

    return newBattle;
  }, []);

  const scheduleEnd = useCallback(
    (battleId: string, continueLoop: (id: string) => void) => {
      clearTimer();
      timerRef.current = setTimeout(() => {
        continueLoop(battleId);
      }, BATTLE_DURATION_MS);
    },
    [clearTimer],
  );

  const continueLoop = useCallback(
    async (endingBattleId: string) => {
      if (isStoppedRef.current || !arenaIdRef.current) return;

      await endBattle(endingBattleId);

      if (isStoppedRef.current) return;

      // Query for next pending battle
      const { data: nextPending } = await supabase
        .from("battles")
        .select("id, state, song_a_id, song_b_id")
        .eq("arena_id", arenaIdRef.current)
        .eq("state", "pending")
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();

      let battleToStart = nextPending;

      if (!battleToStart) {
        battleToStart = await createPendingBattle(arenaIdRef.current);
      }

      if (battleToStart && !isStoppedRef.current) {
        const started = await startBattle(battleToStart.id);
        if (started) {
          scheduleEnd(battleToStart.id, continueLoop);
        }
      }
    },
    [endBattle, createPendingBattle, startBattle, scheduleEnd],
  );

  const initBattleLoop = useCallback(
    async (arenaId: string): Promise<BattleData | null> => {
      arenaIdRef.current = arenaId;
      isStoppedRef.current = false;

      setState((prev) => ({ ...prev, isRunning: true }));

      // Check for existing pending/active battle
      const { data: existingBattle, error } = await supabase
        .from("battles")
        .select("id, state, song_a_id, song_b_id")
        .eq("arena_id", arenaId)
        .in("state", ["pending", "active"])
        .maybeSingle();

      if (error) {
        console.error("[Orchestrator] Failed to fetch battle:", error);
      }

      let currentBattle = existingBattle;

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
