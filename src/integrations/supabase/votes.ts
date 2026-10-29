import { supabase } from "./client";

// "passive": cast by the backend at lock-in (step 9), never by the client
export type VoteType = "regular" | "sudden_death" | "passive";
export type VotingPhase = "active" | "locked" | "sudden_death";

export interface Vote {
  id: string;
  battle_id: string;
  participant_id: string;
  song_id: string;
  status: "active" | "cancelled";
  vote_type: VoteType;
  // Step 14: cast by Music Fighter because they backed this song (a duplicate
  // proposal); false once they switch or toggle it
  preassigned?: boolean;
  created_at: string;
  updated_at: string;
}

export type VoteAction =
  | "created"
  | "toggled_off"
  | "switched"
  | "toggled_on"
  | "locked"
  | "error"
  | "frozen"
  | "sudden_death_created"
  | "sudden_death_upgraded"
  | "sudden_death_immutable"
  | "phase_rejected";

interface BattleState {
  lockin_at: string | null;
  sudden_death_active: boolean;
}

/**
 * Fetches the authoritative battle state from the database.
 * Returns null if battle not found.
 */
async function fetchBattleState(battleId: string): Promise<BattleState | null> {
  const { data, error } = await supabase
    .from("battles")
    .select("lockin_at, sudden_death_active")
    .eq("id", battleId)
    .single();

  if (error || !data) {
    console.error("Failed to fetch battle state:", error);
    return null;
  }

  return {
    lockin_at: data.lockin_at,
    sudden_death_active: data.sudden_death_active ?? false,
  };
}

/**
 * Derives the voting phase from database state.
 * NEVER trust frontend flags for this.
 */
function deriveVotingPhase(battleState: BattleState): VotingPhase {
  if (battleState.lockin_at === null) {
    return "active";
  }

  if (battleState.sudden_death_active === true) {
    return "sudden_death";
  }

  return "locked";
}

function isRlsError(error: { code?: string; message?: string }): boolean {
  return (
    error.code === "42501" ||
    error.message?.includes("row-level security") ||
    error.message?.includes("violates row-level security policy")
  );
}

// The caller's passive vote in a battle (supabase/sql/passive_vote_everyone_2026-10-28.sql):
// before lock-in the song Music Fighter would vote for them, after it the one
// cast; null = none (they voted/abstained, no clear preference, Sudden Death)
export async function getMyPassiveVote(battleId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc("get_my_passive_vote", { p_battle_id: battleId });
  if (error) {
    console.error("Failed to fetch passive vote:", error.message);
    return null;
  }
  return (data as string | null) ?? null;
}

export async function getParticipantVote(battleId: string, participantId: string): Promise<Vote | null> {
  const { data, error } = await supabase
    .from("votes")
    .select("*")
    .eq("battle_id", battleId)
    .eq("participant_id", participantId)
    .maybeSingle();

  if (error) {
    console.error("Failed to fetch vote:", error);
    return null;
  }

  return data;
}

/**
 * Backend-authoritative vote intent handler.
 * Reads battle state from database and enforces all voting rules server-side.
 * The isLockedIn parameter is IGNORED - phase is derived from database only.
 */
export async function applyVoteIntent(
  battleId: string,
  participantId: string,
  songId: string,
  currentVote: Vote | null,
  arenaId: string,
  identityAnchorId: string,
  _isLockedIn: boolean = false, // DEPRECATED: Ignored, phase derived from DB
): Promise<{ vote: Vote | null; action: VoteAction }> {
  // Step 1: Fetch authoritative battle state from database
  const battleState = await fetchBattleState(battleId);
  if (!battleState) {
    console.error("Cannot process vote: battle state unavailable");
    return { vote: null, action: "error" };
  }

  // Step 2: Derive voting phase from database state
  const phase = deriveVotingPhase(battleState);

  // Step 3: Enforce rules based on phase
  switch (phase) {
    case "locked":
      // LOCKED PHASE: Reject ALL vote attempts
      return { vote: null, action: "locked" };

    case "sudden_death":
      // SUDDEN_DEATH PHASE: Only sudden_death votes allowed, with strict rules
      return handleSuddenDeathVote(battleId, participantId, songId, currentVote, arenaId, identityAnchorId);

    case "active":
    default:
      // ACTIVE PHASE: Regular voting allowed
      return handleActivePhaseVote(battleId, participantId, songId, currentVote, arenaId, identityAnchorId);
  }
}

/**
 * Handles voting during ACTIVE phase (before lock-in).
 * Allows: regular votes, switching, toggling.
 * Does NOT allow: sudden_death votes.
 */
async function handleActivePhaseVote(
  battleId: string,
  participantId: string,
  songId: string,
  currentVote: Vote | null,
  arenaId: string,
  identityAnchorId: string,
): Promise<{ vote: Vote | null; action: VoteAction }> {
  // No existing vote - INSERT new active regular vote
  if (!currentVote) {
    const { data, error } = await supabase
      .from("votes")
      .insert({
        battle_id: battleId,
        participant_id: participantId,
        song_id: songId,
        status: "active",
        vote_type: "regular",
        arena_id: arenaId,
        identity_anchor_id: identityAnchorId,
      })
      .select()
      .single();

    if (error) {
      console.error("Failed to insert vote:", error);
      if (isRlsError(error)) {
        return { vote: null, action: "locked" };
      }
      return { vote: null, action: "error" };
    }

    return { vote: data, action: "created" };
  }

  // Existing sudden_death vote - cannot be modified even in active phase
  // (This is a safeguard; sudden_death votes shouldn't exist in active phase)
  if (currentVote.vote_type === "sudden_death") {
    return { vote: currentVote, action: "sudden_death_immutable" };
  }

  // Existing regular vote - allow toggle or switch
  const isSameSong = currentVote.song_id === songId;

  if (isSameSong) {
    // Toggle: active -> cancelled
    const newStatus = currentVote.status === "active" ? "cancelled" : "active";
    const { data, error } = await supabase
      .from("votes")
      .update({ status: newStatus })
      .eq("id", currentVote.id)
      .eq("battle_id", battleId)
      .eq("participant_id", participantId)
      .select()
      .single();

    if (error) {
      console.error("Failed to toggle vote:", error);
      if (isRlsError(error)) {
        return { vote: null, action: "locked" };
      }
      return { vote: null, action: "error" };
    }

    return {
      vote: data,
      action: newStatus === "cancelled" ? "toggled_off" : "toggled_on",
    };
  } else {
    // Different song - switch vote and set active
    const { data, error } = await supabase
      .from("votes")
      .update({
        song_id: songId,
        status: "active",
      })
      .eq("id", currentVote.id)
      .eq("battle_id", battleId)
      .eq("participant_id", participantId)
      .select()
      .single();

    if (error) {
      console.error("Failed to switch vote:", error);
      if (isRlsError(error)) {
        return { vote: null, action: "locked" };
      }
      return { vote: null, action: "error" };
    }

    return { vote: data, action: "switched" };
  }
}

/**
 * Handles voting during SUDDEN_DEATH phase.
 * STRICT RULES:
 * - Only sudden_death votes allowed
 * - Maximum ONE sudden_death vote per user
 * - Existing regular vote can be upgraded (one-time)
 * - Sudden death votes are IMMUTABLE once cast
 */
async function handleSuddenDeathVote(
  battleId: string,
  participantId: string,
  songId: string,
  currentVote: Vote | null,
  arenaId: string,
  identityAnchorId: string,
): Promise<{ vote: Vote | null; action: VoteAction }> {
  // CASE: User already has a sudden_death vote - REJECT (immutable)
  if (currentVote?.vote_type === "sudden_death") {
    return { vote: currentVote, action: "sudden_death_immutable" };
  }

  // CASE: User has a regular vote - upgrade to sudden_death (one-time only)
  if (currentVote?.vote_type === "regular") {
    const { data, error } = await supabase
      .from("votes")
      .update({
        song_id: songId,
        status: "active",
        vote_type: "sudden_death",
      })
      .eq("id", currentVote.id)
      .eq("battle_id", battleId)
      .eq("participant_id", participantId)
      .select()
      .single();

    if (error) {
      console.error("Failed to upgrade vote to sudden_death:", error);
      if (isRlsError(error)) {
        return { vote: null, action: "locked" };
      }
      return { vote: null, action: "error" };
    }

    return { vote: data, action: "sudden_death_upgraded" };
  }

  // CASE: User has no vote - insert new sudden_death vote
  // CASE: User has no prior vote
  // Explicit first-time Sudden Death vote triggered by user action
  // This is NOT an implicit or passive vote
  const { data, error } = await supabase
    .from("votes")
    .insert({
      battle_id: battleId,
      participant_id: participantId,
      song_id: songId,
      status: "active",
      vote_type: "sudden_death",
      arena_id: arenaId,
      identity_anchor_id: identityAnchorId,
    })
    .select()
    .single();

  if (error) {
    console.error("Failed to insert sudden_death vote:", error);
    if (isRlsError(error)) {
      return { vote: null, action: "locked" };
    }
    return { vote: null, action: "error" };
  }

  return { vote: data, action: "sudden_death_created" };
}

export async function getActiveVoteCounts(
  battleId: string,
  voteType?: VoteType,
): Promise<{ songACount: number; songBCount: number; songAId: string | null; songBId: string | null } | null> {
  // First get the battle to know song IDs
  const { data: battle, error: battleError } = await supabase
    .from("battles")
    .select("song_a_id, song_b_id")
    .eq("id", battleId)
    .single();

  if (battleError || !battle) {
    console.error("Failed to fetch battle for vote count:", battleError);
    return null;
  }

  // Count active votes for song A
  let songAQuery = supabase
    .from("votes")
    .select("*", { count: "exact", head: true })
    .eq("battle_id", battleId)
    .eq("song_id", battle.song_a_id)
    .eq("status", "active");

  if (voteType) {
    songAQuery = songAQuery.eq("vote_type", voteType);
  }

  const { count: songACount, error: countAError } = await songAQuery;

  if (countAError) {
    console.error("Failed to count song A votes:", countAError);
    return null;
  }

  // Count active votes for song B
  let songBQuery = supabase
    .from("votes")
    .select("*", { count: "exact", head: true })
    .eq("battle_id", battleId)
    .eq("song_id", battle.song_b_id)
    .eq("status", "active");

  if (voteType) {
    songBQuery = songBQuery.eq("vote_type", voteType);
  }

  const { count: songBCount, error: countBError } = await songBQuery;

  if (countBError) {
    console.error("Failed to count song B votes:", countBError);
    return null;
  }

  return {
    songACount: songACount ?? 0,
    songBCount: songBCount ?? 0,
    songAId: battle.song_a_id,
    songBId: battle.song_b_id,
  };
}
