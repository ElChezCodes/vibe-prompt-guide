import { useEffect, useRef, useState } from "react";
import type { ClosureStateSnapshot } from "./useBattleClosureOrchestrator";

/**
 * Arena post-battle flow hook.
 * Pure operational consumer of backend-derived closure state.
 * Consumes battle results exactly ONCE per battleId (idempotent).
 */

export interface UseArenaFlowReturn {
  hasJustResolved: boolean;
  lastWinnerId: string | null;
  lastWinnerSide: "A" | "B" | null;
  isDraw: boolean;
  acknowledgeResult: () => void;
}

export function useArenaFlow(arenaId: string, closureState: ClosureStateSnapshot): UseArenaFlowReturn {
  const lastConsumedBattleIdRef = useRef<string | null>(null);

  const [hasJustResolved, setHasJustResolved] = useState(false);
  const [lastWinnerId, setLastWinnerId] = useState<string | null>(null);
  const [lastWinnerSide, setLastWinnerSide] = useState<"A" | "B" | null>(null);
  const [isDraw, setIsDraw] = useState(false);

  useEffect(() => {
    // Guard: no battle to observe
    if (!closureState.battleId) {
      return;
    }

    // Guard: battle not yet resolved
    if (!closureState.resolved) {
      return;
    }

    // Idempotency check: already consumed this battle
    if (lastConsumedBattleIdRef.current === closureState.battleId) {
      return;
    }

    // Mark this battle as consumed (idempotent guard)
    lastConsumedBattleIdRef.current = closureState.battleId;

    // Update state from closure snapshot
    setHasJustResolved(true);
    setLastWinnerId(closureState.winnerId);
    setLastWinnerSide(closureState.winnerSide);
    setIsDraw(closureState.isDraw);

    // MVP placeholder: log post-battle consequences
    if (closureState.isDraw) {
      console.log(`[ArenaFlow] Battle ${closureState.battleId} ended in a DRAW. Both songs tied.`);
    } else if (closureState.winnerId) {
      console.log(
        `[ArenaFlow] Battle ${closureState.battleId} resolved. Winner: Song ${closureState.winnerSide} (${closureState.winnerId}). Enqueue placeholder.`,
      );
    }
  }, [
    closureState.battleId,
    closureState.resolved,
    closureState.winnerId,
    closureState.winnerSide,
    closureState.isDraw,
  ]);

  return {
    hasJustResolved,
    lastWinnerId,
    lastWinnerSide,
    isDraw,
    acknowledgeResult,
  };
}
