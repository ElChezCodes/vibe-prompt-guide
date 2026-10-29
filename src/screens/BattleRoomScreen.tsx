import { useState, useEffect, useRef, useCallback } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { getParticipantVote, getMyPassiveVote, applyVoteIntent, Vote } from "@/integrations/supabase/votes";
import { useBattleOrchestrator, ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { useBattleClosureOrchestrator } from "@/hooks/useBattleClosureOrchestrator";
import { useArenaFlow } from "@/hooks/useArenaFlow";
import { useArenaWarmup } from "@/hooks/useArenaWarmup";
import { useArenaPlayback } from "@/hooks/useArenaPlayback";
import NowPlaying from "@/components/streaming/NowPlaying";
import { PAUSE_REASON_LABELS, resumeSpotifyArena } from "@/integrations/supabase/spotify";
import { Pause, Play } from "lucide-react";
import { ensureParticipant } from "@/integrations/supabase/participants";
import StageView, { STAGE_CARD_FOOTER_CLASS } from "@/components/battle/StageView";
import ActionStrip from "@/components/battle/ActionStrip";
import { getMoodLabel, normalizeArenaCode } from "@/integrations/supabase/arenas";
import EndArenaButton from "@/components/arena/EndArenaButton";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { useRefreshCurrentArena } from "@/hooks/useCurrentArena";
import { arenaPath } from "@/lib/arenaRoutes";
import { useArenaPresence } from "@/hooks/useArenaPresence";
import PresenceChip from "@/components/arena/PresenceChip";
import { useArenaQueueSummary } from "@/hooks/useArenaQueueSummary";
import { LOW_QUEUE_THRESHOLD } from "@/integrations/supabase/proposals";
import { getMySongLikes, toggleSongLike } from "@/integrations/supabase/likes";

// "ended": the arena was already finished when opened (no joining possible)
type ScreenState = "loading" | "error" | "ready" | "ended";

interface ArenaData {
  id: string;
  name: string;
  state: string;
  mood: string | null;
  arena_code: string;
  host_id: string | null;
}

interface ParticipantData {
  id: string;
  is_host: boolean;
}

type DerivedBattlePhase = "NORMAL" | "FINAL_30S" | "LOCK_IN" | "SUDDEN_DEATH" | "FINISHED";

/**
 * Derives the UI battle phase from BACKEND STATE + remaining time for display.
 *
 * Backend-authoritative fields used:
 * - battle.state: 'pending' | 'active' | 'closing' | 'completed'
 * - battle.sudden_death_active: boolean (source of truth for sudden death)
 * - battle.locked_at: string | null (source of truth for lock-in)
 * - battle.winner_song_id: string | null (source of truth for resolution)
 *
 * The remainingTime is DISPLAY-ONLY and does not trigger any state changes.
 */
const getDerivedBattlePhase = (battle: ArenaBattleView | null): DerivedBattlePhase => {
  if (!battle) return "NORMAL";

  const debugInfo = { battle_id: battle.battle_id, state: battle.state, resolution_type: battle.resolution_type };

  if (battle.state === "completed") {
    console.log("[DerivedPhase Debug]", { ...debugInfo, returned_phase: "FINISHED", timestamp: Date.now() });
    return "FINISHED";
  }

  // resolution_type is only set at completion, so it can't detect an ongoing SD
  if (battle.state === "closing" && battle.sudden_death_active) {
    console.log("[DerivedPhase Debug]", { ...debugInfo, returned_phase: "SUDDEN_DEATH", timestamp: Date.now() });
    return "SUDDEN_DEATH";
  }

  if (battle.state === "closing") {
    console.log("[DerivedPhase Debug]", { ...debugInfo, returned_phase: "LOCK_IN", timestamp: Date.now() });
    return "LOCK_IN";
  }

  if (battle.state === "active") {
    console.log("[DerivedPhase Debug]", { ...debugInfo, returned_phase: "NORMAL", timestamp: Date.now() });
    return "NORMAL";
  }

  return "NORMAL";
};

const BattleRoomScreen = () => {
  const navigate = useNavigate();
  // The arena travels in the URL (/a/:code/battle), never in router state
  const { code = "" } = useParams();
  const refreshCurrentArena = useRefreshCurrentArena();
  const [screenState, setScreenState] = useState<ScreenState>("loading");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const [arena, setArena] = useState<ArenaData | null>(null);
  const [participant, setParticipant] = useState<ParticipantData | null>(null);
  const [voteRecord, setVoteRecord] = useState<Vote | null>(null);
  const isVotingRef = useRef(false);
  const prevBattleIdRef = useRef<string | null>(null);
  const hasFinalizedRef = useRef(false);

  const { battle, initBattleLoop, stopBattleLoop } = useBattleOrchestrator();

  const { state: closureState, syncFromBattle, reset: resetClosure } = useBattleClosureOrchestrator();

  // Manual likes (step 8 signal); a like is an action, so presence is re-read
  const [likedSongIds, setLikedSongIds] = useState<Set<string>>(new Set());
  const [likeCount, setLikeCount] = useState(0);
  useEffect(() => {
    if (!arena?.id || !participant) return;
    let cancelled = false;
    getMySongLikes(arena.id).then((ids) => {
      if (!cancelled) setLikedSongIds(ids);
    });
    return () => {
      cancelled = true;
    };
  }, [arena?.id, participant]);

  const handleToggleLike = useCallback(
    async (songId: string) => {
      if (!arena?.id || !songId) return;
      try {
        const { liked, voted } = await toggleSongLike(arena.id, songId);
        setLikedSongIds((prev) => {
          const next = new Set(prev);
          if (liked) next.add(songId);
          else next.delete(songId);
          return next;
        });
        setLikeCount((n) => n + 1);
        // The backend cast a vote for the liked song: show it as the user's vote
        if (voted && battle && participant) {
          const vote = await getParticipantVote(battle.battle_id, participant.id);
          if (vote) setVoteRecord(vote);
        }
      } catch (err) {
        console.error("[Like] Failed:", err);
      }
    },
    [arena?.id, battle, participant],
  );

  // The viewer's passive vote (step 9, 2026-10-28: everyone present who hasn't
  // voted), decided by the backend: before lock-in the song MF would vote for
  // them, then the one cast; re-read when the battle phase or their vote changes
  const [passiveSongId, setPassiveSongId] = useState<string | null>(null);
  const passiveBattleId = battle?.battle_id;
  const passiveKey = [battle?.state, battle?.sudden_death_active, voteRecord?.id, voteRecord?.status, voteRecord?.song_id, likeCount].join(":");
  useEffect(() => {
    if (!passiveBattleId || !participant) {
      setPassiveSongId(null);
      return;
    }
    let cancelled = false;
    getMyPassiveVote(passiveBattleId).then((songId) => {
      if (!cancelled) setPassiveSongId(songId);
    });
    return () => {
      cancelled = true;
    };
  }, [passiveBattleId, participant, passiveKey]);

  // ACTIVO/PASIVO/INACTIVO, decided by the backend; re-read after own votes/likes
  const presence = useArenaPresence(arena?.id, !!participant, [voteRecord?.id, voteRecord?.song_id, voteRecord?.status, voteRecord?.vote_type, voteRecord?.updated_at, likeCount].join(":"));

  const handleVote = useCallback(
    async (side: "A" | "B") => {
      const isVotablePhase = battle?.state === "active" || (battle?.state === "closing" && battle?.sudden_death_active);
      if (!battle || !isVotablePhase || !participant || !arena || arena.state !== "active") {
        console.log("[Vote] Blocked - battle/arena not active or missing data");
        return;
      }

      if (isVotingRef.current) {
        console.log("[Vote] Blocked - vote in progress");
        return;
      }

      // Get identity anchor from session
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session?.user) {
        console.log("[Vote] Blocked - no session");
        return;
      }

      isVotingRef.current = true;
      const songId = side === "A" ? battle.song_a_id : battle.song_b_id;

      console.log(`[Vote] Processing vote for Song ${side} (${songId})`);

      const { vote, action } = await applyVoteIntent(
        battle.battle_id,
        participant.id,
        songId,
        voteRecord,
        arena.id,
        session.user.id,
      );

      if (action === "locked") {
        console.log("[Vote] Battle is locked - voting not allowed");
        isVotingRef.current = false;
        return;
      }

      console.log(`[Vote] Action: ${action}`, vote);

      if (vote) {
        setVoteRecord(vote);
      }

      isVotingRef.current = false;
    },
    [battle, participant, voteRecord, arena],
  );

  const arenaId = arena?.id;

  const { hasJustResolved, lastWinnerSide, isDraw, acknowledgeResult } = useArenaFlow(arenaId ?? "", closureState);

  // Warm-up: first track of the arena's Spotify playlist (host's device)
  const { warmup, isWarmupPlaying } = useArenaWarmup(arenaId, arena?.state);

  // Arena pause is decided server-side (Spotify watcher); display only
  const playback = useArenaPlayback(arenaId, arena?.state === "active");
  // Step 12b: no pair for the next battle yet / few human proposals left
  const queueSummary = useArenaQueueSummary(arenaId, arena?.state === "active");
  const isPaused = !!playback?.paused_at;
  const [resumeError, setResumeError] = useState("");
  const handleResume = async () => {
    if (!arenaId) return;
    setResumeError("");
    try {
      await resumeSpotifyArena(arenaId);
    } catch (err) {
      setResumeError(err instanceof Error ? err.message : String(err));
    }
  };

  // Reset vote state and sync closure when battle changes
  useEffect(() => {
    if (battle?.battle_id !== prevBattleIdRef.current) {
      hasFinalizedRef.current = false; // 🔑 RESET OBLIGATORIO

      if (prevBattleIdRef.current !== null) {
        setVoteRecord(null);
        resetClosure();
      }

      prevBattleIdRef.current = battle?.battle_id ?? null;

      if (battle?.battle_id) {
        syncFromBattle(battle.battle_id);
      }
    }
  }, [battle?.battle_id, syncFromBattle, resetClosure]);

  // Consume resolution result (UI-side only)
  useEffect(() => {
    if (!hasJustResolved) return;

    console.log("[BattleRoomScreen] Battle resolved:", isDraw ? "DRAW" : `Winner side ${lastWinnerSide}`);

    // MVP behavior: acknowledge immediately
    acknowledgeResult();
  }, [hasJustResolved, isDraw, lastWinnerSide, acknowledgeResult]);

  useEffect(() => {
    const loadBattleRoom = async () => {
      try {
        // Get current auth session for identity
        const {
          data: { session },
        } = await supabase.auth.getSession();
        if (!session?.user) {
          setErrorMessage("No authenticated session");
          setScreenState("error");
          return;
        }

        const identityAnchorId = session.user.id;

        // Fetch arena data
        // Expired arenas are hidden by RLS, so they also land in "not found"
        const { data: arenaData, error: arenaError } = await supabase
          .from("arenas")
          .select("id, name, state, mood, arena_code, host_id")
          .eq("arena_code", normalizeArenaCode(code))
          .maybeSingle();

        if (arenaError || !arenaData) {
          console.error("Failed to fetch arena:", arenaError);
          setErrorMessage("Arena not found");
          setScreenState("error");
          return;
        }

        // Joining a finished arena is rejected by RLS; just say it's over
        if (arenaData.state === "finished") {
          setArena(arenaData);
          setScreenState("ended");
          return;
        }

        // Entering is the (re-)join: idempotent, clears a previous "Leave arena".
        // Host-ness is the arena's host_id (RLS enforces the same rule).
        const isHost = arenaData.host_id === identityAnchorId;
        const participantData = await ensureParticipant(arenaData.id, identityAnchorId, isHost);
        refreshCurrentArena();

        setArena(arenaData);
        setParticipant(participantData);
        setScreenState("ready");

        // Initialize battle loop via orchestrator
        const currentBattle = await initBattleLoop(arenaData.id);

        // Load existing vote if battle is active
        if (currentBattle?.state === "active") {
          const existingVote = await getParticipantVote(currentBattle.battle_id, participantData.id);
          if (existingVote) {
            setVoteRecord(existingVote);
          }
        }
      } catch (err) {
        console.error("Battle room load error:", err);
        setErrorMessage("Failed to load battle room");
        setScreenState("error");
      }
    };

    loadBattleRoom();

    return () => {
      stopBattleLoop();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [code, initBattleLoop, stopBattleLoop]);

  // Arena state is backend-owned (start_arena_battles / end_arena); follow it live
  useEffect(() => {
    if (!arenaId) return;

    const channel = supabase
      .channel(`arenas:id=eq.${arenaId}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "arenas", filter: `id=eq.${arenaId}` },
        (payload) => {
          const row = payload.new as Partial<ArenaData>;
          setArena((prev) => (prev ? { ...prev, state: row.state ?? prev.state, mood: row.mood ?? prev.mood } : prev));
        },
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [arenaId]);

  // A finished arena stops being anyone's current arena (tabs, Home shortcut)
  useEffect(() => {
    if (arena?.state === "finished") refreshCurrentArena();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [arena?.state]);

  if (screenState === "loading") {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center space-bg">
        <p className="neon-label animate-pulse">Loading arena...</p>
      </div>
    );
  }

  if (screenState === "error") {
    return <ScreenMessage message={errorMessage} isError />;
  }

  if (screenState === "ended") {
    return <ScreenMessage message="This arena has ended" />;
  }

  const derivedPhase = getDerivedBattlePhase(battle);

  // Check if user has already voted in sudden death (vote_type === 'sudden_death')
  const hasSuddenDeathVote = voteRecord?.vote_type === "sudden_death";

  // Voting enabled exclusively by backend state (battle AND arena). In Sudden
  // Death each participant gets one final vote (new, or upgrade of a regular one).
  const isVotingEnabled =
    arena?.state === "active" &&
    !isPaused &&
    (battle?.state === "active" || (derivedPhase === "SUDDEN_DEATH" && !hasSuddenDeathVote));
  const moodLabel = getMoodLabel(arena?.mood);

  // In Sudden Death the tension bar counts only sudden_death votes, so only
  // highlight the user's pick once it is a sudden_death vote.
  const displayedVote = derivedPhase === "SUDDEN_DEATH" && !hasSuddenDeathVote ? null : voteRecord;
  // An active vote of theirs replaces the passive one at once (the backend
  // agrees on the next read); none in Sudden Death
  const hasOwnVote = !!voteRecord && voteRecord.vote_type !== "passive";
  const displayedPassive = hasOwnVote || derivedPhase === "SUDDEN_DEATH" ? null : passiveSongId;

  return (
    <div className="relative min-h-dvh w-full">
      {/* Presentational layer */}
      <StageView
        key={battle?.battle_id}
        arena={arena!}
        battle={battle}
        participant={participant!}
        currentVote={displayedVote}
        passiveVoteSongId={displayedPassive}
        derivedPhase={derivedPhase}
        pausedAt={playback?.paused_at ?? null}
        likedSongIds={likedSongIds}
        onToggleLike={arena?.state === "active" ? handleToggleLike : undefined}
      />

      {/* Invisible interaction layer - positioned above StageView */}
      {isVotingEnabled && (
        <div className="absolute inset-0 z-50 pointer-events-none">
          {/* Match the layout of StageView's battle arena section */}
          <div className="min-h-dvh w-full flex flex-col">
            {/* Spacer for tension bar + timer */}
            <div className="pt-8 px-8">
              <div className="h-3" />
            </div>
            <div className="py-8">
              <div className="h-16 lg:h-24" />
            </div>

            {/* Clickable song areas */}
            <div className="flex-1 flex items-center justify-center px-8 lg:px-16">
              <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
                {/* Song A hit area */}
                <div className="flex-1 max-w-md">
                  <div
                    className="aspect-square pointer-events-auto cursor-pointer"
                    onClick={() => handleVote("A")}
                    role="button"
                    aria-label="Vote for Song A"
                  />
                  {/* StageView's card footer ("Open Spotify") stays clickable */}
                  <div className={STAGE_CARD_FOOTER_CLASS} />
                </div>

                {/* VS spacer */}
                <div className="flex-shrink-0 w-16 lg:w-24" />

                {/* Song B hit area */}
                <div className="flex-1 max-w-md">
                  <div
                    className="aspect-square pointer-events-auto cursor-pointer"
                    onClick={() => handleVote("B")}
                    role="button"
                    aria-label="Vote for Song B"
                  />
                  <div className={STAGE_CARD_FOOTER_CLASS} />
                </div>
              </div>
            </div>

            <div className="h-16 lg:h-24" />
          </div>
        </div>
      )}

      {/* Arena-level status (backend arenas.state) */}
      {arena?.state === "waiting" && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="mx-6 px-6 py-5 rounded-2xl neon-panel text-center animate-fade-in">
            <p className="neon-label mb-2">Get ready</p>
            <p className="text-xl font-bold text-foreground">Waiting for the host to start battles</p>
            {moodLabel && (
              <p className="mt-2 text-sm text-text-secondary">
                Tonight's mood: <span className="text-song-b font-medium">{moodLabel}</span>
              </p>
            )}
          </div>
        </div>
      )}

      {arena?.state === "finished" && (
        <div className="absolute inset-0 z-[60] flex items-center justify-center bg-background/75 backdrop-blur-sm">
          <div className="mx-6 px-8 py-7 rounded-2xl neon-panel text-center animate-scale-in">
            <p className="neon-heading text-2xl">Arena Finished</p>
            <p className="mt-2 text-sm text-text-secondary">Thanks for playing</p>
            <button
              onClick={() => navigate("/")}
              className="mt-5 w-full h-11 px-4 rounded-md bg-primary text-primary-foreground text-sm font-bold glow-primary hover:bg-primary/90 transition-colors"
            >
              Back to start
            </button>
          </div>
        </div>
      )}

      {/* Way out of the battle without leaving the arena (Paso_2 §3 keeps the
          battle itself menu-free; this only switches to the app zone) */}
      {arena?.state !== "finished" && (
        <div className="absolute top-2 left-2 z-[55] flex gap-2">
          <button
            onClick={() => navigate("/")}
            className="hud-chip px-3 py-1 rounded-full text-xs font-medium transition-colors"
          >
            ← App
          </button>
          {participant?.is_host && (
            <button
              onClick={() => navigate(arenaPath(arena.arena_code, "lobby"))}
              className="hud-chip px-3 py-1 rounded-full text-xs font-medium transition-colors"
            >
              Lobby
            </button>
          )}
          <PresenceChip state={presence?.my_state} />
        </div>
      )}

      {/* Warm-up now playing (display-only window from warmup_started_at) */}
      {warmup && isWarmupPlaying && (
        <div className="absolute top-11 left-2 z-[55] max-w-[60%]">
          <div className="hud-chip flex items-center gap-2 px-3 py-1 rounded-full text-xs border-primary/50">
            <span className="flex-shrink-0 text-primary font-semibold">♪ Warm-up</span>
            <span className="truncate text-foreground">
              {warmup.title} · {warmup.artist}
            </span>
          </div>
        </div>
      )}

      {/* No pair for the next battle: the backend creates it as soon as songs arrive */}
      {arena?.state === "active" && !isPaused && queueSummary?.waiting_for_songs && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="mx-6 px-6 py-5 rounded-2xl neon-panel text-center animate-fade-in">
            <p className="neon-label mb-2">Waiting for songs</p>
            <p className="text-sm text-text-secondary">Propose a song and the next battle starts</p>
          </div>
        </div>
      )}

      {arena?.state === "active" &&
        !isPaused &&
        queueSummary &&
        !queueSummary.waiting_for_songs &&
        queueSummary.human_queued < LOW_QUEUE_THRESHOLD && (
          <div className="absolute inset-x-0 top-20 z-[55] flex justify-center px-4 pointer-events-none">
            <p className="hud-chip px-3 py-1 rounded-full text-xs text-song-b">The queue is running low: propose a song!</p>
          </div>
        )}

      {/* Arena paused (Spotify device/playback): battle clock frozen, votes closed */}
      {isPaused && (
        <div className="absolute inset-x-0 top-11 z-[60] flex justify-center px-3 animate-fade-in">
          <div
            role="status"
            className="w-full max-w-md rounded-2xl border border-energy-yellow/50 bg-background/90 backdrop-blur-md px-3 py-2.5 shadow-[0_0_28px_-8px_hsl(var(--energy-yellow)/0.7)]"
          >
            <div className="flex items-center gap-3">
              <span className="w-9 h-9 flex-shrink-0 rounded-xl bg-energy-yellow/15 border border-energy-yellow/40 flex items-center justify-center">
                <Pause className="w-4 h-4 text-energy-yellow" fill="currentColor" />
              </span>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-bold uppercase tracking-wider text-energy-yellow leading-tight">Arena paused</p>
                <p className="text-xs text-text-secondary leading-snug">
                  {PAUSE_REASON_LABELS[playback.pause_reason] ?? "Spotify isn't playing"}. It resumes by itself when the
                  music is back.
                </p>
              </div>
              {participant?.is_host && (
                <button
                  onClick={handleResume}
                  className="flex-shrink-0 inline-flex items-center gap-1 px-3 py-2 rounded-full bg-primary text-primary-foreground text-xs font-bold glow-primary hover:brightness-110 transition"
                >
                  <Play className="w-3.5 h-3.5" fill="currentColor" />
                  <span className="hidden min-[380px]:inline">Resume on Spotify</span>
                  <span className="min-[380px]:hidden">Resume</span>
                </button>
              )}
            </div>
            {resumeError && <p className="mt-1.5 text-xs text-destructive">{resumeError}</p>}
          </div>
        </div>
      )}

      {participant?.is_host && (arena?.state === "waiting" || arena?.state === "active") && (
        <div className="absolute top-2 right-2 z-[55]">
          {/* Realtime UPDATE will also arrive; set eagerly from the confirmed RPC result */}
          <EndArenaButton
            arenaId={arena.id}
            onEnded={() => setArena((prev) => (prev ? { ...prev, state: "finished" } : prev))}
          >
            <button className="hud-chip hud-chip-danger px-3 py-1 rounded-full text-xs font-medium transition-colors">
              End Arena
            </button>
          </EndArenaButton>
        </div>
      )}

      {/* Bottom stack (above the vote layer, so taps here never vote): what the
          host's Spotify plays (step 18), then Propose Song, one under the other */}
      {(arena?.state === "waiting" || arena?.state === "active") && (
        <div className="absolute bottom-0 inset-x-0 z-[55] flex flex-col items-center">
          {arena.state === "active" && !isPaused && (
            <div className="w-full max-w-sm px-4 pt-2">
              <NowPlaying arenaId={arena.id} playback={playback} isHost={!!participant?.is_host} />
            </div>
          )}
          {/* Proposals allowed in waiting and active (Block 2 §8); RLS enforces it too */}
          {derivedPhase !== "SUDDEN_DEATH" ? <ActionStrip arenaId={arena.id} /> : <div className="h-2" />}
        </div>
      )}

      {/* Sudden Death vote submitted confirmation */}
      {derivedPhase === "SUDDEN_DEATH" && hasSuddenDeathVote && (
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 z-50 pointer-events-none">
          <div className="px-4 py-2 rounded-full bg-primary/15 border border-primary/60 text-primary text-sm font-bold glow-primary">
            Vote submitted
          </div>
        </div>
      )}
    </div>
  );
};

export default BattleRoomScreen;
