import { useState, useCallback, useEffect, useRef } from 'react';
import {
  BattleClosureState,
  BattleClosureResult,
  VoteAggregate,
  BattleState,
  BattleTimingConfig,
  initializeClosureState,
  getClosureState,
  clearClosureState,
  handleLockinReached,
  canAcceptRegularVote,
  canAcceptSuddenDeathVote,
  applySuddenDeathVote,
  registerSuddenDeathVote,
  handleBattleTimerEnded,
  initializeBattleTiming,
  isLockinReached,
  isSuddenDeathActive,
  isResolved,
  getWinner,
  getVoteCounts,
  getBattleTiming,
  getSuddenDeathDurationMs,
  getLockinOffsetMs,
} from '@/lib/battleClosureOrchestrator';

export interface ClosureStateSnapshot {
  battleId: string | null;
  isLockinReached: boolean;
  lockinReachedAt: string | null;
  suddenDeathActive: boolean;
  suddenDeathStartedAt: string | null;
  resolved: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  bothSongsWin: boolean;
  hadSuddenDeath: boolean;
  regularSongACount: number;
  regularSongBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
  totalSongA: number;
  totalSongB: number;
  battleStartAt: string | null;
  battleEndAt: string | null;
  lockinAt: string | null;
}

export interface UseBattleClosureOrchestratorReturn {
  state: ClosureStateSnapshot;
  initialize: (battleId: string, battleState: BattleState) => void;
  initializeTiming: (battleId: string, config: BattleTimingConfig) => Promise<{
    success: boolean;
    battleEndAt: string | null;
    lockinAt: string | null;
  }>;
  triggerLockinReached: () => Promise<{
    success: boolean;
    suddenDeathActive: boolean;
    aggregates: VoteAggregate | null;
  }>;
  triggerBattleEnd: () => Promise<BattleClosureResult>;
  checkCanVoteRegular: (participantId: string) => Promise<{ allowed: boolean; reason: string }>;
  checkCanVoteSuddenDeath: (participantId: string) => Promise<{ allowed: boolean; reason: string }>;
  submitSuddenDeathVote: (
    participantId: string,
    songId: string,
    arenaId: string,
    identityAnchorId: string
  ) => Promise<{ success: boolean; action: 'created' | 'upgraded' | 'rejected'; reason: string }>;
  recordSuddenDeathVote: (participantId: string) => boolean;
  reset: () => void;
  refreshState: () => void;
  getSuddenDeathDuration: () => number;
  getLockinOffset: () => number;
}

const initialState: ClosureStateSnapshot = {
  battleId: null,
  isLockinReached: false,
  lockinReachedAt: null,
  suddenDeathActive: false,
  suddenDeathStartedAt: null,
  resolved: false,
  winnerId: null,
  winnerSide: null,
  isDraw: false,
  bothSongsWin: false,
  hadSuddenDeath: false,
  regularSongACount: 0,
  regularSongBCount: 0,
  suddenDeathSongACount: 0,
  suddenDeathSongBCount: 0,
  totalSongA: 0,
  totalSongB: 0,
  battleStartAt: null,
  battleEndAt: null,
  lockinAt: null,
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
  const timing = getBattleTiming(battleId);

  return {
    battleId,
    isLockinReached: isLockinReached(battleId),
    lockinReachedAt: closureState.lockinReachedAt,
    suddenDeathActive: isSuddenDeathActive(battleId),
    suddenDeathStartedAt: closureState.suddenDeathStartedAt,
    resolved: isResolved(battleId),
    winnerId: winner.winnerId,
    winnerSide: winner.winnerSide,
    isDraw: winner.isDraw,
    bothSongsWin: winner.bothSongsWin,
    hadSuddenDeath: closureState.hadSuddenDeath,
    regularSongACount: voteCounts.regularSongACount,
    regularSongBCount: voteCounts.regularSongBCount,
    suddenDeathSongACount: voteCounts.suddenDeathSongACount,
    suddenDeathSongBCount: voteCounts.suddenDeathSongBCount,
    totalSongA: voteCounts.totalSongA,
    totalSongB: voteCounts.totalSongB,
    battleStartAt: timing.battleStartAt,
    battleEndAt: timing.battleEndAt,
    lockinAt: timing.lockinAt,
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

  const initializeTiming = useCallback(async (battleId: string, config: BattleTimingConfig) => {
    battleIdRef.current = battleId;
    const result = await initializeBattleTiming(battleId, config);
    refreshState();
    return result;
  }, [refreshState]);

  const triggerLockinReached = useCallback(async () => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { success: false, suddenDeathActive: false, aggregates: null };
    }

    const result = await handleLockinReached(battleId);
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
        bothSongsWin: false,
        songATotal: 0,
        songBTotal: 0,
        hadSuddenDeath: false,
      };
    }

    const result = await handleBattleTimerEnded(battleId);
    refreshState();
    return result;
  }, [refreshState]);

  const checkCanVoteRegular = useCallback(async (participantId: string) => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { allowed: true, reason: '' };
    }
    return canAcceptRegularVote(battleId, participantId);
  }, []);

  const checkCanVoteSuddenDeath = useCallback(async (participantId: string) => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { allowed: false, reason: 'No active battle' };
    }
    return canAcceptSuddenDeathVote(battleId, participantId);
  }, []);

  const submitSuddenDeathVote = useCallback(async (
    participantId: string,
    songId: string,
    arenaId: string,
    identityAnchorId: string
  ) => {
    const battleId = battleIdRef.current;
    if (!battleId) {
      return { success: false, action: 'rejected' as const, reason: 'No active battle' };
    }
    const result = await applySuddenDeathVote(battleId, participantId, songId, arenaId, identityAnchorId);
    if (result.success) {
      refreshState();
    }
    return result;
  }, [refreshState]);

  const recordSuddenDeathVoteLocal = useCallback((participantId: string) => {
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

  const getSuddenDeathDuration = useCallback(() => {
    return getSuddenDeathDurationMs();
  }, []);

  const getLockinOffset = useCallback(() => {
    return getLockinOffsetMs();
  }, []);

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

    window.addEventListener('battle:closed', handleBattleClosed as EventListener);
    window.addEventListener('battle:lockin_reached', handleLockinReachedEvent as EventListener);
    window.addEventListener('battle:sudden_death_started', handleSuddenDeathStarted as EventListener);
    
    return () => {
      window.removeEventListener('battle:closed', handleBattleClosed as EventListener);
      window.removeEventListener('battle:lockin_reached', handleLockinReachedEvent as EventListener);
      window.removeEventListener('battle:sudden_death_started', handleSuddenDeathStarted as EventListener);
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
    initializeTiming,
    triggerLockinReached,
    triggerBattleEnd,
    checkCanVoteRegular,
    checkCanVoteSuddenDeath,
    submitSuddenDeathVote,
    recordSuddenDeathVote: recordSuddenDeathVoteLocal,
    reset,
    refreshState,
    getSuddenDeathDuration,
    getLockinOffset,
  };
}
