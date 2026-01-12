import { useState, useCallback, useEffect, useRef } from 'react';
import {
  BattleClosureState,
  BattleClosureResult,
  VoteAggregate,
  BattleState,
  initializeClosureState,
  getClosureState,
  clearClosureState,
  handleLockIn,
  handleBattleTimerEnded,
  canAcceptSuddenDeathVote,
  registerSuddenDeathVote,
  isLocked,
  isSuddenDeathActive,
  isResolved,
  getWinner,
  getVoteCounts,
} from '@/lib/battleClosureOrchestrator';

export interface ClosureStateSnapshot {
  battleId: string | null;
  isLocked: boolean;
  lockedAt: string | null;
  suddenDeathActive: boolean;
  resolved: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  songACount: number;
  songBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
}

export interface UseBattleClosureOrchestratorReturn {
  state: ClosureStateSnapshot;
  initialize: (battleId: string, battleState: BattleState) => void;
  triggerLockIn: () => Promise<{
    success: boolean;
    suddenDeathActive: boolean;
    aggregates: VoteAggregate | null;
  }>;
  triggerBattleEnd: () => Promise<BattleClosureResult>;
  checkCanVoteSuddenDeath: (participantId: string) => Promise<{ allowed: boolean; reason: string }>;
  recordSuddenDeathVote: (participantId: string) => boolean;
  reset: () => void;
  refreshState: () => void;
}

const initialState: ClosureStateSnapshot = {
  battleId: null,
  isLocked: false,
  lockedAt: null,
  suddenDeathActive: false,
  resolved: false,
  winnerId: null,
  winnerSide: null,
  isDraw: false,
  songACount: 0,
  songBCount: 0,
  suddenDeathSongACount: 0,
  suddenDeathSongBCount: 0,
};

function snapshotFromOrchestrator(battleId: string | null): ClosureStateSnapshot {
  if (!battleId) {
    return initialState;
  }

  const closureState = getClosureState(battleId);
  if (!closureState) {
    return { ...initialState, battleId };
  }

  const voteCounts = getVoteCounts(battleId);
  const winner = getWinner(battleId);

  return {
    battleId,
    isLocked: isLocked(battleId),
    lockedAt: closureState.lockedAt,
    suddenDeathActive: isSuddenDeathActive(battleId),
    resolved: isResolved(battleId),
    winnerId: winner.winnerId,
    winnerSide: winner.winnerSide,
    isDraw: winner.isDraw,
    songACount: voteCounts.songACount,
    songBCount: voteCounts.songBCount,
    suddenDeathSongACount: voteCounts.suddenDeathSongACount,
    suddenDeathSongBCount: voteCounts.suddenDeathSongBCount,
  };
}

export function useBattleClosureOrchestrator(): UseBattleClosureOrchestratorReturn {
  const [state, setState] = useState<ClosureStateSnapshot>(initialState);
  const battleIdRef = useRef<string | null>(null);

  const refreshState = useCallback(() => {
    setState(snapshotFromOrchestrator(battleIdRef.current));
  }, []);

  const initialize = useCallback((battleId: string, battleState: BattleState) => {
    battleIdRef.current = battleId;
    initializeClosureState(battleId, battleState);
    refreshState();
  }, [refreshState]);

  const triggerLockIn = useCallback(async () => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { success: false, suddenDeathActive: false, aggregates: null };
    }

    const result = await handleLockIn(battleId);
    refreshState();
    return result;
  }, [refreshState]);

  const triggerBattleEnd = useCallback(async () => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return {
        success: false,
        winnerId: null,
        winnerSide: null,
        isDraw: false,
        songATotal: 0,
        songBTotal: 0,
      };
    }

    const result = await handleBattleTimerEnded(battleId);
    refreshState();
    return result;
  }, [refreshState]);

  const checkCanVoteSuddenDeath = useCallback(async (participantId: string) => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { allowed: false, reason: 'No active battle' };
    }
    return canAcceptSuddenDeathVote(battleId, participantId);
  }, []);

  const recordSuddenDeathVote = useCallback((participantId: string) => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return false;
    }
    const success = registerSuddenDeathVote(battleId, participantId);
    if (success) {
      refreshState();
    }
    return success;
  }, [refreshState]);

  const reset = useCallback(() => {
    const battleId = battleIdRef.current;
    if (battleId) {
      clearClosureState(battleId);
    }
    battleIdRef.current = null;
    setState(initialState);
  }, []);

  useEffect(() => {
    const handleBattleEnded = (event: CustomEvent) => {
      const { battleId } = event.detail;
      if (battleId === battleIdRef.current) {
        refreshState();
      }
    };

    window.addEventListener('battle:ended', handleBattleEnded as EventListener);
    return () => {
      window.removeEventListener('battle:ended', handleBattleEnded as EventListener);
    };
  }, [refreshState]);

  useEffect(() => {
    return () => {
      const battleId = battleIdRef.current;
      if (battleId) {
        clearClosureState(battleId);
      }
    };
  }, []);

  return {
    state,
    initialize,
    triggerLockIn,
    triggerBattleEnd,
    checkCanVoteSuddenDeath,
    recordSuddenDeathVote,
    reset,
    refreshState,
  };
}
