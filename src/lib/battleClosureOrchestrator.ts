import { supabase } from "@/integrations/supabase/client";

export type BattleState = 'pending' | 'active' | 'closing' | 'completed';

export interface BattleClosureState {
  battleId: string;
  battleState: BattleState;
  lockedAt: string | null;
  suddenDeathActive: boolean;
  suddenDeathVoters: Set<string>;
  resolved: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  songACount: number;
  songBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
}

export interface BattleClosureResult {
  success: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  songATotal: number;
  songBTotal: number;
}

export interface VoteAggregate {
  songACount: number;
  songBCount: number;
  songAId: string | null;
  songBId: string | null;
}

export interface BattleData {
  id: string;
  arena_id: string;
  song_a_id: string;
  song_b_id: string;
  state: BattleState;
  started_at: string | null;
  ended_at: string | null;
  locked_at: string | null;
  sudden_death_active: boolean;
  winner_song_id: string | null;
}

const closureStates = new Map<string, BattleClosureState>();

function getOrCreateState(battleId: string): BattleClosureState {
  let state = closureStates.get(battleId);
  if (!state) {
    state = {
      battleId,
      battleState: 'pending',
      lockedAt: null,
      suddenDeathActive: false,
      suddenDeathVoters: new Set(),
      resolved: false,
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      songACount: 0,
      songBCount: 0,
      suddenDeathSongACount: 0,
      suddenDeathSongBCount: 0,
    };
    closureStates.set(battleId, state);
  }
  return state;
}

export function initializeClosureState(battleId: string, battleState: BattleState): BattleClosureState {
  const state = getOrCreateState(battleId);
  state.battleState = battleState;
  return state;
}

export function getClosureState(battleId: string): BattleClosureState | null {
  return closureStates.get(battleId) || null;
}

export function clearClosureState(battleId: string): void {
  closureStates.delete(battleId);
}

async function fetchVoteAggregatesAtTimestamp(
  battleId: string,
  songAId: string,
  songBId: string,
  timestamp: string | null
): Promise<VoteAggregate> {
  let songAQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songAId)
    .eq('status', 'active');

  let songBQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songBId)
    .eq('status', 'active');

  if (timestamp) {
    songAQuery = songAQuery.lte('created_at', timestamp);
    songBQuery = songBQuery.lte('created_at', timestamp);
  }

  const [songAResult, songBResult] = await Promise.all([songAQuery, songBQuery]);

  return {
    songACount: songAResult.count ?? 0,
    songBCount: songBResult.count ?? 0,
    songAId,
    songBId,
  };
}

async function fetchSuddenDeathVotes(
  battleId: string,
  songAId: string,
  songBId: string,
  lockedAt: string
): Promise<{ songACount: number; songBCount: number }> {
  const { data: suddenDeathVotes, error } = await supabase
    .from('votes')
    .select('id, song_id, participant_id')
    .eq('battle_id', battleId)
    .eq('status', 'active')
    .gt('created_at', lockedAt);

  if (error || !suddenDeathVotes) {
    console.error('Failed to fetch sudden death votes:', error);
    return { songACount: 0, songBCount: 0 };
  }

  const participantIds = [...new Set(suddenDeathVotes.map(v => v.participant_id))];

  if (participantIds.length === 0) {
    return { songACount: 0, songBCount: 0 };
  }

  const { data: activeParticipants, error: participantsError } = await supabase
    .from('participants')
    .select('id')
    .in('id', participantIds)
    .eq('status', 'active');

  if (participantsError) {
    console.error('Failed to fetch participant statuses:', participantsError);
    return { songACount: 0, songBCount: 0 };
  }

  const activeParticipantIds = new Set(activeParticipants?.map(p => p.id) ?? []);

  let songACount = 0;
  let songBCount = 0;

  for (const vote of suddenDeathVotes) {
    if (activeParticipantIds.has(vote.participant_id)) {
      if (vote.song_id === songAId) {
        songACount++;
      } else if (vote.song_id === songBId) {
        songBCount++;
      }
    }
  }

  return { songACount, songBCount };
}

async function fetchBattle(battleId: string): Promise<BattleData | null> {
  const { data, error } = await supabase
    .from('battles')
    .select('id, arena_id, song_a_id, song_b_id, state, started_at, ended_at, locked_at, sudden_death_active, winner_song_id')
    .eq('id', battleId)
    .single();

  if (error || !data) {
    console.error('Failed to fetch battle:', error);
    return null;
  }

  return data as BattleData;
}

async function updateBattleState(
  battleId: string,
  updates: Partial<{
    state: BattleState;
    locked_at: string;
    sudden_death_active: boolean;
    ended_at: string;
    winner_song_id: string | null;
  }>
): Promise<boolean> {
  const { error } = await supabase
    .from('battles')
    .update(updates)
    .eq('id', battleId);

  if (error) {
    console.error('Failed to update battle state:', error);
    return false;
  }

  return true;
}

export async function handleLockIn(battleId: string): Promise<{
  success: boolean;
  suddenDeathActive: boolean;
  aggregates: VoteAggregate | null;
}> {
  const state = getOrCreateState(battleId);

  if (state.lockedAt !== null) {
    return {
      success: true,
      suddenDeathActive: state.suddenDeathActive,
      aggregates: {
        songACount: state.songACount,
        songBCount: state.songBCount,
        songAId: null,
        songBId: null,
      },
    };
  }

  const battle = await fetchBattle(battleId);
  if (!battle) {
    return { success: false, suddenDeathActive: false, aggregates: null };
  }

  if (battle.state !== 'active') {
    console.warn('Cannot lock-in: battle state is not active');
    return { success: false, suddenDeathActive: false, aggregates: null };
  }

  const lockedAt = new Date().toISOString();
  const aggregates = await fetchVoteAggregatesAtTimestamp(
    battleId,
    battle.song_a_id,
    battle.song_b_id,
    lockedAt
  );

  const isTied = aggregates.songACount === aggregates.songBCount;

  state.lockedAt = lockedAt;
  state.suddenDeathActive = isTied;
  state.songACount = aggregates.songACount;
  state.songBCount = aggregates.songBCount;
  state.battleState = 'active';

  const updateSuccess = await updateBattleState(battleId, {
    locked_at: lockedAt,
    sudden_death_active: isTied,
  });

  if (!updateSuccess) {
    state.lockedAt = null;
    state.suddenDeathActive = false;
    return { success: false, suddenDeathActive: false, aggregates: null };
  }

  return {
    success: true,
    suddenDeathActive: isTied,
    aggregates: {
      ...aggregates,
      songAId: battle.song_a_id,
      songBId: battle.song_b_id,
    },
  };
}

export async function canAcceptSuddenDeathVote(
  battleId: string,
  participantId: string
): Promise<{ allowed: boolean; reason: string }> {
  const state = closureStates.get(battleId);

  if (!state) {
    return { allowed: false, reason: 'Battle closure state not initialized' };
  }

  if (state.battleState !== 'active') {
    return { allowed: false, reason: 'Battle is not active' };
  }

  if (!state.suddenDeathActive) {
    return { allowed: false, reason: 'Sudden death is not active' };
  }

  if (state.suddenDeathVoters.has(participantId)) {
    return { allowed: false, reason: 'Participant already voted in sudden death' };
  }

  const { data: participant, error } = await supabase
    .from('participants')
    .select('status')
    .eq('id', participantId)
    .single();

  if (error || !participant) {
    return { allowed: false, reason: 'Participant not found' };
  }

  if (participant.status !== 'active') {
    return { allowed: false, reason: 'Participant is not active' };
  }

  return { allowed: true, reason: '' };
}

export function registerSuddenDeathVote(
  battleId: string,
  participantId: string
): boolean {
  const state = closureStates.get(battleId);

  if (!state) {
    return false;
  }

  if (state.suddenDeathVoters.has(participantId)) {
    return false;
  }

  state.suddenDeathVoters.add(participantId);
  return true;
}

export async function handleBattleTimerEnded(
  battleId: string
): Promise<BattleClosureResult> {
  const state = getOrCreateState(battleId);

  if (state.resolved) {
    return {
      success: true,
      winnerId: state.winnerId,
      winnerSide: state.winnerSide,
      isDraw: state.isDraw,
      songATotal: state.songACount + state.suddenDeathSongACount,
      songBTotal: state.songBCount + state.suddenDeathSongBCount,
    };
  }

  const battle = await fetchBattle(battleId);
  if (!battle) {
    return {
      success: false,
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      songATotal: 0,
      songBTotal: 0,
    };
  }

  if (battle.state !== 'active') {
    console.warn('Cannot end battle: state is not active');
    return {
      success: false,
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      songATotal: 0,
      songBTotal: 0,
    };
  }

  const transitionSuccess = await updateBattleState(battleId, {
    state: 'closing',
  });

  if (!transitionSuccess) {
    return {
      success: false,
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      songATotal: 0,
      songBTotal: 0,
    };
  }

  state.battleState = 'closing';

  const lockedAt = state.lockedAt || battle.locked_at;
  const normalVotes = await fetchVoteAggregatesAtTimestamp(
    battleId,
    battle.song_a_id,
    battle.song_b_id,
    lockedAt
  );

  state.songACount = normalVotes.songACount;
  state.songBCount = normalVotes.songBCount;

  let suddenDeathVotes = { songACount: 0, songBCount: 0 };
  const suddenDeathWasActive = state.suddenDeathActive || battle.sudden_death_active;

  if (suddenDeathWasActive && lockedAt) {
    suddenDeathVotes = await fetchSuddenDeathVotes(
      battleId,
      battle.song_a_id,
      battle.song_b_id,
      lockedAt
    );
    state.suddenDeathSongACount = suddenDeathVotes.songACount;
    state.suddenDeathSongBCount = suddenDeathVotes.songBCount;
  }

  const totalSongA = state.songACount + state.suddenDeathSongACount;
  const totalSongB = state.songBCount + state.suddenDeathSongBCount;

  let winnerId: string | null = null;
  let winnerSide: 'A' | 'B' | null = null;
  let isDraw = false;

  if (totalSongA > totalSongB) {
    winnerId = battle.song_a_id;
    winnerSide = 'A';
  } else if (totalSongB > totalSongA) {
    winnerId = battle.song_b_id;
    winnerSide = 'B';
  } else {
    isDraw = true;
  }

  state.winnerId = winnerId;
  state.winnerSide = winnerSide;
  state.isDraw = isDraw;
  state.resolved = true;

  await executeSideEffects(battleId, battle.arena_id, winnerId, winnerSide, isDraw);

  const finalSuccess = await updateBattleState(battleId, {
    state: 'completed',
    ended_at: new Date().toISOString(),
    winner_song_id: winnerId,
  });

  if (finalSuccess) {
    state.battleState = 'completed';
  }

  return {
    success: true,
    winnerId,
    winnerSide,
    isDraw,
    songATotal: totalSongA,
    songBTotal: totalSongB,
  };
}

async function executeSideEffects(
  battleId: string,
  arenaId: string,
  winnerId: string | null,
  winnerSide: 'A' | 'B' | null,
  isDraw: boolean
): Promise<void> {
  if (winnerId && !isDraw) {
    await enqueueWinningSong(arenaId, winnerId);
  }

  emitBattleEndedEvent(battleId, winnerId, winnerSide, isDraw);

  await updateStatistics(battleId, arenaId, winnerId);

  cleanup(battleId);
}

async function enqueueWinningSong(arenaId: string, songId: string): Promise<void> {
  console.log(`[Closure] Enqueuing winning song ${songId} to arena ${arenaId} playlist`);
}

function emitBattleEndedEvent(
  battleId: string,
  winnerId: string | null,
  winnerSide: 'A' | 'B' | null,
  isDraw: boolean
): void {
  const event = new CustomEvent('battle:ended', {
    detail: {
      battleId,
      winnerId,
      winnerSide,
      isDraw,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:ended event for battle ${battleId}`);
}

async function updateStatistics(
  battleId: string,
  arenaId: string,
  winnerId: string | null
): Promise<void> {
  console.log(`[Closure] Updating statistics for battle ${battleId} in arena ${arenaId}`);
}

function cleanup(battleId: string): void {
  console.log(`[Closure] Cleanup initiated for battle ${battleId}`);
}

export function isLocked(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.lockedAt !== null;
}

export function isSuddenDeathActive(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.suddenDeathActive ?? false;
}

export function isResolved(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.resolved ?? false;
}

export function getWinner(battleId: string): { winnerId: string | null; winnerSide: 'A' | 'B' | null; isDraw: boolean } {
  const state = closureStates.get(battleId);
  if (!state || !state.resolved) {
    return { winnerId: null, winnerSide: null, isDraw: false };
  }
  return {
    winnerId: state.winnerId,
    winnerSide: state.winnerSide,
    isDraw: state.isDraw,
  };
}

export function getVoteCounts(battleId: string): {
  songACount: number;
  songBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
} {
  const state = closureStates.get(battleId);
  if (!state) {
    return {
      songACount: 0,
      songBCount: 0,
      suddenDeathSongACount: 0,
      suddenDeathSongBCount: 0,
    };
  }
  return {
    songACount: state.songACount,
    songBCount: state.songBCount,
    suddenDeathSongACount: state.suddenDeathSongACount,
    suddenDeathSongBCount: state.suddenDeathSongBCount,
  };
}
