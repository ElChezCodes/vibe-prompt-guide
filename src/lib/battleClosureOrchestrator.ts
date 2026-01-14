import { supabase } from "@/integrations/supabase/client";

export type BattleState = 'pending' | 'active' | 'closing' | 'completed';
export type VoteType = 'regular' | 'sudden_death';

export interface BattleClosureState {
  battleId: string;
  battleState: BattleState;
  battleStartAt: string | null;
  battleEndAt: string | null;
  lockinAt: string | null;
  lockinReached: boolean;
  lockinReachedAt: string | null;
  suddenDeathActive: boolean;
  suddenDeathStartedAt: string | null;
  suddenDeathVoters: Set<string>;
  resolved: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  hadSuddenDeath: boolean;
  regularSongACount: number;
  regularSongBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
}

export interface BattleClosureResult {
  success: boolean;
  winnerId: string | null;
  winnerSide: 'A' | 'B' | null;
  isDraw: boolean;
  bothSongsWin: boolean;
  songATotal: number;
  songBTotal: number;
  hadSuddenDeath: boolean;
}

export interface VoteAggregate {
  songACount: number;
  songBCount: number;
  songAId: string | null;
  songBId: string | null;
  isTied: boolean;
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
  lockin_at: string | null;
  battle_end_at: string | null;
  sudden_death_active: boolean;
  winner_song_id: string | null;
  had_sudden_death: boolean;
  is_special_battle: boolean;
}

export interface BattleTimingConfig {
  songADurationMs: number;
  songBDurationMs: number;
  playSingleSong: boolean;
}

const SUDDEN_DEATH_DURATION_MS = 15000;
const LOCKIN_OFFSET_MS = 15000;

const closureStates = new Map<string, BattleClosureState>();

function getOrCreateState(battleId: string): BattleClosureState {
  let state = closureStates.get(battleId);
  if (!state) {
    state = {
      battleId,
      battleState: 'pending',
      battleStartAt: null,
      battleEndAt: null,
      lockinAt: null,
      lockinReached: false,
      lockinReachedAt: null,
      suddenDeathActive: false,
      suddenDeathStartedAt: null,
      suddenDeathVoters: new Set(),
      resolved: false,
      winnerId: null,
      winnerSide: null,
      isDraw: false,
      hadSuddenDeath: false,
      regularSongACount: 0,
      regularSongBCount: 0,
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

export function computeBattleTiming(
  startTime: Date,
  config: BattleTimingConfig
): { battleStartAt: string; battleEndAt: string; lockinAt: string } {
  let totalDurationMs: number;
  
  if (config.playSingleSong) {
    totalDurationMs = Math.max(config.songADurationMs, config.songBDurationMs);
  } else {
    totalDurationMs = config.songADurationMs + config.songBDurationMs;
  }
  
  const battleStartAt = startTime.toISOString();
  const battleEndAt = new Date(startTime.getTime() + totalDurationMs).toISOString();
  const lockinAt = new Date(startTime.getTime() + totalDurationMs - LOCKIN_OFFSET_MS).toISOString();
  
  return { battleStartAt, battleEndAt, lockinAt };
}

async function fetchRegularVoteCounts(
  battleId: string,
  songAId: string,
  songBId: string
): Promise<{ songACount: number; songBCount: number }> {
  const songAQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songAId)
    .eq('status', 'active')
    .eq('vote_type', 'regular');

  const songBQuery = supabase
    .from('votes')
    .select('*', { count: 'exact', head: true })
    .eq('battle_id', battleId)
    .eq('song_id', songBId)
    .eq('status', 'active')
    .eq('vote_type', 'regular');

  const [songAResult, songBResult] = await Promise.all([songAQuery, songBQuery]);

  return {
    songACount: songAResult.count ?? 0,
    songBCount: songBResult.count ?? 0,
  };
}

async function fetchSuddenDeathVoteCounts(
  battleId: string,
  songAId: string,
  songBId: string
): Promise<{ songACount: number; songBCount: number }> {
  const { data: suddenDeathVotes, error } = await supabase
    .from('votes')
    .select('id, song_id, participant_id')
    .eq('battle_id', battleId)
    .eq('status', 'active')
    .eq('vote_type', 'sudden_death');

  if (error || !suddenDeathVotes) {
    console.error('Failed to fetch sudden death votes:', error);
    return { songACount: 0, songBCount: 0 };
  }

  if (suddenDeathVotes.length === 0) {
    return { songACount: 0, songBCount: 0 };
  }

  const participantIds = [...new Set(suddenDeathVotes.map(v => v.participant_id))];

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
    .select('id, arena_id, song_a_id, song_b_id, state, started_at, ended_at, locked_at, lockin_at, battle_end_at, sudden_death_active, winner_song_id, had_sudden_death, is_special_battle')
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
    started_at: string;
    ended_at: string;
    locked_at: string;
    lockin_at: string;
    battle_end_at: string;
    sudden_death_active: boolean;
    winner_song_id: string | null;
    had_sudden_death: boolean;
    is_special_battle: boolean;
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

export async function initializeBattleTiming(
  battleId: string,
  config: BattleTimingConfig
): Promise<{ success: boolean; battleEndAt: string | null; lockinAt: string | null }> {
  const state = getOrCreateState(battleId);
  
  const startTime = new Date();
  const timing = computeBattleTiming(startTime, config);
  
  state.battleStartAt = timing.battleStartAt;
  state.battleEndAt = timing.battleEndAt;
  state.lockinAt = timing.lockinAt;
  state.battleState = 'active';
  
  const success = await updateBattleState(battleId, {
    state: 'active',
    started_at: timing.battleStartAt,
    lockin_at: timing.lockinAt,
    battle_end_at: timing.battleEndAt,
  });
  
  if (!success) {
    return { success: false, battleEndAt: null, lockinAt: null };
  }
  
  return { 
    success: true, 
    battleEndAt: timing.battleEndAt, 
    lockinAt: timing.lockinAt 
  };
}

export async function handleLockinReached(battleId: string): Promise<{
  success: boolean;
  suddenDeathActive: boolean;
  aggregates: VoteAggregate | null;
}> {
  const state = getOrCreateState(battleId);

  if (state.lockinReached) {
    return {
      success: true,
      suddenDeathActive: state.suddenDeathActive,
      aggregates: {
        songACount: state.regularSongACount,
        songBCount: state.regularSongBCount,
        songAId: null,
        songBId: null,
        isTied: state.regularSongACount === state.regularSongBCount,
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

  const lockinReachedAt = new Date().toISOString();
  
  const regularVotes = await fetchRegularVoteCounts(
    battleId,
    battle.song_a_id,
    battle.song_b_id
  );

  const isTied = regularVotes.songACount === regularVotes.songBCount;

  state.lockinReached = true;
  state.lockinReachedAt = lockinReachedAt;
  state.regularSongACount = regularVotes.songACount;
  state.regularSongBCount = regularVotes.songBCount;
  state.suddenDeathActive = isTied;
  state.hadSuddenDeath = isTied;

  if (isTied) {
    state.suddenDeathStartedAt = lockinReachedAt;
    emitSuddenDeathStartedEvent(battleId);
  }

  const updateSuccess = await updateBattleState(battleId, {
    locked_at: lockinReachedAt,
    sudden_death_active: isTied,
    had_sudden_death: isTied,
  });

  if (!updateSuccess) {
    state.lockinReached = false;
    state.lockinReachedAt = null;
    state.suddenDeathActive = false;
    state.hadSuddenDeath = false;
    state.suddenDeathStartedAt = null;
    return { success: false, suddenDeathActive: false, aggregates: null };
  }

  emitLockinReachedEvent(battleId, isTied);

  return {
    success: true,
    suddenDeathActive: isTied,
    aggregates: {
      songACount: regularVotes.songACount,
      songBCount: regularVotes.songBCount,
      songAId: battle.song_a_id,
      songBId: battle.song_b_id,
      isTied,
    },
  };
}

export async function canAcceptRegularVote(
  battleId: string,
  participantId: string
): Promise<{ allowed: boolean; reason: string }> {
  const state = closureStates.get(battleId);

  if (!state) {
    return { allowed: true, reason: '' };
  }

  if (state.battleState !== 'active') {
    return { allowed: false, reason: 'Battle is not active' };
  }

  if (state.lockinReached) {
    return { allowed: false, reason: 'Voting is frozen after lock-in' };
  }

  return { allowed: true, reason: '' };
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

export async function applySuddenDeathVote(
  battleId: string,
  participantId: string,
  songId: string,
  arenaId: string,
  identityAnchorId: string
): Promise<{ success: boolean; action: 'created' | 'upgraded' | 'rejected'; reason: string }> {
  const canVote = await canAcceptSuddenDeathVote(battleId, participantId);
  
  if (!canVote.allowed) {
    return { success: false, action: 'rejected', reason: canVote.reason };
  }

  const { data: existingVote, error: fetchError } = await supabase
    .from('votes')
    .select('*')
    .eq('battle_id', battleId)
    .eq('participant_id', participantId)
    .maybeSingle();

  if (fetchError) {
    console.error('Failed to fetch existing vote:', fetchError);
    return { success: false, action: 'rejected', reason: 'Database error' };
  }

  const state = closureStates.get(battleId);

  if (existingVote) {
    const { error: updateError } = await supabase
      .from('votes')
      .update({
        song_id: songId,
        vote_type: 'sudden_death',
        status: 'active',
        updated_at: new Date().toISOString(),
      })
      .eq('id', existingVote.id)
      .eq('battle_id', battleId)
      .eq('participant_id', participantId);

    if (updateError) {
      console.error('Failed to upgrade vote to sudden death:', updateError);
      return { success: false, action: 'rejected', reason: 'Failed to update vote' };
    }

    if (state) {
      state.suddenDeathVoters.add(participantId);
    }

    return { success: true, action: 'upgraded', reason: '' };
  } else {
    const { error: insertError } = await supabase
      .from('votes')
      .insert({
        battle_id: battleId,
        participant_id: participantId,
        song_id: songId,
        vote_type: 'sudden_death',
        status: 'active',
        arena_id: arenaId,
        identity_anchor_id: identityAnchorId,
      });

    if (insertError) {
      console.error('Failed to insert sudden death vote:', insertError);
      return { success: false, action: 'rejected', reason: 'Failed to create vote' };
    }

    if (state) {
      state.suddenDeathVoters.add(participantId);
    }

    return { success: true, action: 'created', reason: '' };
  }
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
    const totalSongA = state.regularSongACount + state.suddenDeathSongACount;
    const totalSongB = state.regularSongBCount + state.suddenDeathSongBCount;
    const bothSongsWin = state.isDraw && state.hadSuddenDeath;
    
    return {
      success: true,
      winnerId: state.winnerId,
      winnerSide: state.winnerSide,
      isDraw: state.isDraw,
      bothSongsWin,
      songATotal: totalSongA,
      songBTotal: totalSongB,
      hadSuddenDeath: state.hadSuddenDeath,
    };
  }

  const battle = await fetchBattle(battleId);
  if (!battle) {
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

  if (battle.state !== 'active') {
    console.warn('Cannot end battle: state is not active');
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

  const transitionSuccess = await updateBattleState(battleId, {
    state: 'closing',
  });

  if (!transitionSuccess) {
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

  state.battleState = 'closing';

  const regularVotes = await fetchRegularVoteCounts(
    battleId,
    battle.song_a_id,
    battle.song_b_id
  );

  state.regularSongACount = regularVotes.songACount;
  state.regularSongBCount = regularVotes.songBCount;

  let suddenDeathVotes = { songACount: 0, songBCount: 0 };
  const suddenDeathWasActive = state.hadSuddenDeath || battle.had_sudden_death || state.suddenDeathActive || battle.sudden_death_active;

  if (suddenDeathWasActive) {
    suddenDeathVotes = await fetchSuddenDeathVoteCounts(
      battleId,
      battle.song_a_id,
      battle.song_b_id
    );
    state.suddenDeathSongACount = suddenDeathVotes.songACount;
    state.suddenDeathSongBCount = suddenDeathVotes.songBCount;
    state.hadSuddenDeath = true;
  }

  const totalSongA = state.regularSongACount + state.suddenDeathSongACount;
  const totalSongB = state.regularSongBCount + state.suddenDeathSongBCount;

  let winnerId: string | null = null;
  let winnerSide: 'A' | 'B' | null = null;
  let isDraw = false;
  let bothSongsWin = false;

  if (totalSongA > totalSongB) {
    winnerId = battle.song_a_id;
    winnerSide = 'A';
  } else if (totalSongB > totalSongA) {
    winnerId = battle.song_b_id;
    winnerSide = 'B';
  } else {
    isDraw = true;
    if (state.hadSuddenDeath) {
      bothSongsWin = true;
    }
  }

  state.winnerId = winnerId;
  state.winnerSide = winnerSide;
  state.isDraw = isDraw;
  state.resolved = true;

  await persistFinalVoteSnapshot(battleId, state);

  await executeSideEffects(
    battleId, 
    battle.arena_id, 
    battle.song_a_id,
    battle.song_b_id,
    winnerId, 
    winnerSide, 
    isDraw, 
    bothSongsWin,
    state.hadSuddenDeath
  );

  const finalSuccess = await updateBattleState(battleId, {
    state: 'completed',
    ended_at: new Date().toISOString(),
    winner_song_id: winnerId,
    had_sudden_death: state.hadSuddenDeath,
  });

  if (finalSuccess) {
    state.battleState = 'completed';
  }

  return {
    success: true,
    winnerId,
    winnerSide,
    isDraw,
    bothSongsWin,
    songATotal: totalSongA,
    songBTotal: totalSongB,
    hadSuddenDeath: state.hadSuddenDeath,
  };
}

async function persistFinalVoteSnapshot(
  battleId: string,
  state: BattleClosureState
): Promise<void> {
  console.log(`[Closure] Persisting final vote snapshot for battle ${battleId}:`, {
    regularSongACount: state.regularSongACount,
    regularSongBCount: state.regularSongBCount,
    suddenDeathSongACount: state.suddenDeathSongACount,
    suddenDeathSongBCount: state.suddenDeathSongBCount,
    hadSuddenDeath: state.hadSuddenDeath,
    lockinReachedAt: state.lockinReachedAt,
  });
}

async function executeSideEffects(
  battleId: string,
  arenaId: string,
  songAId: string,
  songBId: string,
  winnerId: string | null,
  winnerSide: 'A' | 'B' | null,
  isDraw: boolean,
  bothSongsWin: boolean,
  hadSuddenDeath: boolean
): Promise<void> {
  if (bothSongsWin) {
    await enqueueWinningSong(arenaId, songAId);
    await enqueueWinningSong(arenaId, songBId);
    await markNextBattleAsSpecial(arenaId, songAId, songBId);
  } else if (winnerId && !isDraw) {
    await enqueueWinningSong(arenaId, winnerId);
  }

  emitBattleClosedEvent(battleId, winnerId, winnerSide, isDraw, bothSongsWin, hadSuddenDeath);

  await updateStatistics(battleId, arenaId, winnerId, bothSongsWin);

  cleanup(battleId);
}

async function enqueueWinningSong(arenaId: string, songId: string): Promise<void> {
  console.log(`[Closure] Enqueuing winning song ${songId} to arena ${arenaId} playlist`);
}

async function markNextBattleAsSpecial(arenaId: string, songAId: string, songBId: string): Promise<void> {
  console.log(`[Closure] Marking next battle as SPECIAL for arena ${arenaId}`);
  console.log(`[Closure] Both songs will be used: ${songAId} and ${songBId}`);
}

function emitLockinReachedEvent(battleId: string, suddenDeathActive: boolean): void {
  const event = new CustomEvent('battle:lockin_reached', {
    detail: {
      battleId,
      suddenDeathActive,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:lockin_reached event for battle ${battleId}, suddenDeath: ${suddenDeathActive}`);
}

function emitSuddenDeathStartedEvent(battleId: string): void {
  const event = new CustomEvent('battle:sudden_death_started', {
    detail: {
      battleId,
      timestamp: new Date().toISOString(),
      durationMs: SUDDEN_DEATH_DURATION_MS,
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:sudden_death_started event for battle ${battleId}`);
}

function emitBattleClosedEvent(
  battleId: string,
  winnerId: string | null,
  winnerSide: 'A' | 'B' | null,
  isDraw: boolean,
  bothSongsWin: boolean,
  hadSuddenDeath: boolean
): void {
  const event = new CustomEvent('battle:closed', {
    detail: {
      battleId,
      winnerId,
      winnerSide,
      isDraw,
      bothSongsWin,
      hadSuddenDeath,
      timestamp: new Date().toISOString(),
    },
  });
  window.dispatchEvent(event);
  console.log(`[Closure] Emitted battle:closed event for battle ${battleId}`);
}

async function updateStatistics(
  battleId: string,
  arenaId: string,
  winnerId: string | null,
  bothSongsWin: boolean
): Promise<void> {
  console.log(`[Closure] Updating statistics for battle ${battleId} in arena ${arenaId}, bothSongsWin: ${bothSongsWin}`);
}

function cleanup(battleId: string): void {
  console.log(`[Closure] Cleanup initiated for battle ${battleId}`);
}

export function isLockinReached(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.lockinReached ?? false;
}

export function isSuddenDeathActive(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.suddenDeathActive ?? false;
}

export function isResolved(battleId: string): boolean {
  const state = closureStates.get(battleId);
  return state?.resolved ?? false;
}

export function getWinner(battleId: string): { 
  winnerId: string | null; 
  winnerSide: 'A' | 'B' | null; 
  isDraw: boolean;
  bothSongsWin: boolean;
} {
  const state = closureStates.get(battleId);
  if (!state || !state.resolved) {
    return { winnerId: null, winnerSide: null, isDraw: false, bothSongsWin: false };
  }
  const bothSongsWin = state.isDraw && state.hadSuddenDeath;
  return {
    winnerId: state.winnerId,
    winnerSide: state.winnerSide,
    isDraw: state.isDraw,
    bothSongsWin,
  };
}

export function getVoteCounts(battleId: string): {
  regularSongACount: number;
  regularSongBCount: number;
  suddenDeathSongACount: number;
  suddenDeathSongBCount: number;
  totalSongA: number;
  totalSongB: number;
} {
  const state = closureStates.get(battleId);
  if (!state) {
    return {
      regularSongACount: 0,
      regularSongBCount: 0,
      suddenDeathSongACount: 0,
      suddenDeathSongBCount: 0,
      totalSongA: 0,
      totalSongB: 0,
    };
  }
  return {
    regularSongACount: state.regularSongACount,
    regularSongBCount: state.regularSongBCount,
    suddenDeathSongACount: state.suddenDeathSongACount,
    suddenDeathSongBCount: state.suddenDeathSongBCount,
    totalSongA: state.regularSongACount + state.suddenDeathSongACount,
    totalSongB: state.regularSongBCount + state.suddenDeathSongBCount,
  };
}

export function getBattleTiming(battleId: string): {
  battleStartAt: string | null;
  battleEndAt: string | null;
  lockinAt: string | null;
  lockinReachedAt: string | null;
  suddenDeathStartedAt: string | null;
} {
  const state = closureStates.get(battleId);
  if (!state) {
    return {
      battleStartAt: null,
      battleEndAt: null,
      lockinAt: null,
      lockinReachedAt: null,
      suddenDeathStartedAt: null,
    };
  }
  return {
    battleStartAt: state.battleStartAt,
    battleEndAt: state.battleEndAt,
    lockinAt: state.lockinAt,
    lockinReachedAt: state.lockinReachedAt,
    suddenDeathStartedAt: state.suddenDeathStartedAt,
  };
}

export function getSuddenDeathDurationMs(): number {
  return SUDDEN_DEATH_DURATION_MS;
}

export function getLockinOffsetMs(): number {
  return LOCKIN_OFFSET_MS;
}


