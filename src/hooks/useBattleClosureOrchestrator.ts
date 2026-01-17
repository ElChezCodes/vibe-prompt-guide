import { useEffect, useMemo } from "react";
import { useBattleOrchestrator } from "@/hooks/useBattleOrchestrator";

/**
 * This hook is a PURE BACKEND OBSERVER.
 *
 * ❗ It does NOT:
 * - count votes
 * - detect ties
 * - activate sudden death
 * - resolve winners
 * - manage timers
 *
 * ✅ It ONLY reflects backend-authoritative state from `battles`
 * and derives UI-safe flags for rendering.
 */

export type DerivedBattlePhase = "pending" | "active" | "lockin" | "sudden_death" | "completed";

export interface BattleClosureSnapshot {
  battleId: string | null;

  // backend fields
  state: "pending" | "active" | "closing" | "completed";
  lockedAt: string | null;
  lockinAt: string | null;
  suddenDeathActive: boolean;
  winnerSongId: string | null;
  hadSuddenDeath: boolean;

  // derived (UI-only)
  derivedPhase: DerivedBattlePhase;
  isLocked: boolean;
  isResolved: boolean;
  bothSongsWin: boolean;
}

export function useBattleClosureOrchestrator() {
  const { battle } = useBattleOrchestrator();

  /**
   * Derive UI phase strictly from BACKEND STATE.
   * No timers. No local heuristics.
   */
  const derivedPhase: DerivedBattlePhase = useMemo(() => {
    if (!battle) return "pending";

    if (battle.state === "completed") return "completed";

    if (battle.sudden_death_active) return "sudden_death";

    if (battle.locked_at) return "lockin";

    if (battle.state === "active") return "active";

    return "pending";
  }, [battle]);

  const snapshot: BattleClosureSnapshot = useMemo(() => {
    if (!battle) {
      return {
        battleId: null,
        state: "pending",
        lockedAt: null,
        lockinAt: null,
        suddenDeathActive: false,
        winnerSongId: null,
        hadSuddenDeath: false,
        derivedPhase: "pending",
        isLocked: false,
        isResolved: false,
        bothSongsWin: false,
      };
    }

    const isResolved = battle.state === "completed";
    const isLocked = Boolean(battle.locked_at);
    const bothSongsWin = isResolved && battle.winner_song_id === null && battle.had_sudden_death;

    return {
      battleId: battle.id,
      state: battle.state,
      lockedAt: battle.locked_at,
      lockinAt: battle.lockin_at,
      suddenDeathActive: battle.sudden_death_active,
      winnerSongId: battle.winner_song_id,
      hadSuddenDeath: battle.had_sudden_death,
      derivedPhase,
      isLocked,
      isResolved,
      bothSongsWin,
    };
  }, [battle, derivedPhase]);

  /**
   * Optional: helpful debug signal in Lovable logs
   */
  useEffect(() => {
    if (!battle) return;
    console.log("[ClosureObserver]", {
      battleId: battle.id,
      phase: snapshot.derivedPhase,
      lockedAt: snapshot.lockedAt,
      suddenDeath: snapshot.suddenDeathActive,
      resolved: snapshot.isResolved,
    });
  }, [battle, snapshot]);

  return snapshot;
}
