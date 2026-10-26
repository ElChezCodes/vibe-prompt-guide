import { useState, useEffect, useRef, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { getParticipantVote, applyVoteIntent, Vote } from "@/integrations/supabase/votes";
import { useBattleOrchestrator, ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { useBattleClosureOrchestrator } from "@/hooks/useBattleClosureOrchestrator";
import { useArenaFlow } from "@/hooks/useArenaFlow";
import { useArenaWarmup } from "@/hooks/useArenaWarmup";
import { ensureParticipant } from "@/integrations/supabase/participants";
import StageView from "@/components/battle/StageView";
import ActionStrip from "@/components/battle/ActionStrip";
import { endArena, getMoodLabel } from "@/integrations/supabase/arenas";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";

type ScreenState = "loading" | "error" | "ready";

interface ArenaData {
  id: string;
  name: string;
  state: string;
  mood: string | null;
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
  const location = useLocation();
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

  const arenaId = location.state?.arenaId as string | undefined;
  const roleIntent = location.state?.role_intent as "host" | "participant" | undefined;

  const { hasJustResolved, lastWinnerSide, isDraw, acknowledgeResult } = useArenaFlow(arenaId ?? "", closureState);

  // Warm-up: first song of the session; the host's browser plays it for now
  const { warmup, isWarmupPlaying, needsTap, resumeWarmup } = useArenaWarmup(
    arenaId,
    arena?.state,
    !!participant?.is_host,
  );

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
        if (!arenaId) {
          setErrorMessage("No arena ID provided");
          setScreenState("error");
          return;
        }

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
        const { data: arenaData, error: arenaError } = await supabase
          .from("arenas")
          .select("id, name, state, mood")
          .eq("id", arenaId)
          .single();

        if (arenaError || !arenaData) {
          console.error("Failed to fetch arena:", arenaError);
          setErrorMessage("Arena not found");
          setScreenState("error");
          return;
        }

        // Register participant based on role_intent (idempotent)
        const isHost = roleIntent === "host";
        const participantData = await ensureParticipant(arenaId, identityAnchorId, isHost);

        setArena(arenaData);
        setParticipant(participantData);
        setScreenState("ready");

        // Initialize battle loop via orchestrator
        const currentBattle = await initBattleLoop(arenaId);

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
  }, [arenaId, roleIntent, initBattleLoop, stopBattleLoop]);

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

  const handleEndArena = async () => {
    if (!arena) return;
    try {
      await endArena(arena.id);
      // Realtime UPDATE will also arrive; set eagerly from the confirmed RPC result
      setArena((prev) => (prev ? { ...prev, state: "finished" } : prev));
    } catch {
      // logged in endArena; arena state stays as the backend reports it
    }
  };

  if (screenState === "loading") {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-muted-foreground">Loading...</p>
      </div>
    );
  }

  if (screenState === "error") {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-destructive">{errorMessage}</p>
      </div>
    );
  }

  const derivedPhase = getDerivedBattlePhase(battle);

  // Check if user has already voted in sudden death (vote_type === 'sudden_death')
  const hasSuddenDeathVote = voteRecord?.vote_type === "sudden_death";

  // Voting enabled exclusively by backend state (battle AND arena). In Sudden
  // Death each participant gets one final vote (new, or upgrade of a regular one).
  const isVotingEnabled =
    arena?.state === "active" &&
    (battle?.state === "active" || (derivedPhase === "SUDDEN_DEATH" && !hasSuddenDeathVote));
  const moodLabel = getMoodLabel(arena?.mood);

  // In Sudden Death the tension bar counts only sudden_death votes, so only
  // highlight the user's pick once it is a sudden_death vote.
  const displayedVote = derivedPhase === "SUDDEN_DEATH" && !hasSuddenDeathVote ? null : voteRecord;

  return (
    <div className="relative min-h-dvh w-full">
      {/* Presentational layer */}
      <StageView
        key={battle?.battle_id}
        arena={arena!}
        battle={battle}
        participant={participant!}
        currentVote={displayedVote}
        derivedPhase={derivedPhase}
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
                <div
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote("A")}
                  role="button"
                  aria-label="Vote for Song A"
                />

                {/* VS spacer */}
                <div className="flex-shrink-0 w-16 lg:w-24" />

                {/* Song B hit area */}
                <div
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote("B")}
                  role="button"
                  aria-label="Vote for Song B"
                />
              </div>
            </div>

            <div className="h-16 lg:h-24" />
          </div>
        </div>
      )}

      {/* Arena-level status (backend arenas.state) */}
      {arena?.state === "waiting" && (
        <div className="absolute inset-0 z-40 flex items-center justify-center pointer-events-none">
          <div className="px-6 py-4 rounded-xl bg-black/70 text-white text-center">
            <p className="text-xl font-bold">Waiting for the host to start battles</p>
            {moodLabel && <p className="mt-1 text-sm text-white/70">Tonight's mood: {moodLabel}</p>}
          </div>
        </div>
      )}

      {arena?.state === "finished" && (
        <div className="absolute inset-0 z-[60] flex items-center justify-center bg-black/60">
          <div className="px-6 py-4 rounded-xl bg-black/80 text-white text-center">
            <p className="text-2xl font-arcade font-black tracking-widest">ARENA FINISHED</p>
            <p className="mt-1 text-sm text-white/70">Thanks for playing</p>
          </div>
        </div>
      )}

      {/* Warm-up now playing (display-only window from warmup_started_at) */}
      {warmup && isWarmupPlaying && (
        <div className="absolute top-2 left-2 z-[55] max-w-[60%]">
          <div className="flex items-center gap-2 px-3 py-1 rounded-md bg-black/50 border border-white/20 text-xs text-white/80">
            <span className="flex-shrink-0">♪ Warm-up</span>
            <span className="truncate text-white">
              {warmup.title} · {warmup.artist}
            </span>
            {participant?.is_host && needsTap && (
              <button
                onClick={resumeWarmup}
                className="flex-shrink-0 px-2 py-0.5 rounded bg-primary text-primary-foreground font-medium"
              >
                Play
              </button>
            )}
          </div>
        </div>
      )}

      {participant?.is_host && (arena?.state === "waiting" || arena?.state === "active") && (
        <div className="absolute top-2 right-2 z-[55]">
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <button className="px-3 py-1 rounded-md bg-black/50 border border-white/20 text-xs text-white/80 hover:text-white">
                End Arena
              </button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>End this arena?</AlertDialogTitle>
                <AlertDialogDescription>
                  Battles stop and no more votes or proposals are accepted. This can't be undone.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={handleEndArena}>End Arena</AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
      )}

      {/* Proposals allowed in waiting and active (Block 2 §8); RLS enforces it too */}
      {(arena?.state === "waiting" || arena?.state === "active") && derivedPhase !== "SUDDEN_DEATH" && (
        <div className="absolute bottom-0 inset-x-0 z-[55]">
          <ActionStrip arenaId={arena.id} />
        </div>
      )}

      {/* Sudden Death vote submitted confirmation */}
      {derivedPhase === "SUDDEN_DEATH" && hasSuddenDeathVote && (
        <div className="absolute bottom-8 left-1/2 -translate-x-1/2 z-50 pointer-events-none">
          <div className="px-4 py-2 rounded-lg bg-primary/20 border border-primary/40 text-primary text-sm font-medium">
            Vote submitted
          </div>
        </div>
      )}
    </div>
  );
};

export default BattleRoomScreen;
