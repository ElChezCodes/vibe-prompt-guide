import { useState, useEffect, useRef, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { getParticipantVote, applyVoteIntent, Vote } from "@/integrations/supabase/votes";
import { useBattleOrchestrator, ArenaBattleView } from "@/hooks/useBattleOrchestrator";
import { useBattleClosureOrchestrator } from "@/hooks/useBattleClosureOrchestrator";
import { useArenaFlow } from "@/hooks/useArenaFlow";
import { ensureParticipant } from "@/integrations/supabase/participants";
import StageView from "@/components/battle/StageView";

type ScreenState = "loading" | "error" | "ready";

interface ArenaData {
  id: string;
  name: string;
  state: string;
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
const getDerivedBattlePhase = (
  battle: ArenaBattleView | null,
): DerivedBattlePhase => {
  if (!battle) return "NORMAL";

  // FINISHED ONLY when backend says completed
  if (battle.state === "completed") {
    return "FINISHED";
  }

  // Sudden Death remains backend-authoritative
  if (battle.resolution_type === "sudden_death") {
    return "SUDDEN_DEATH";
  }

  // LOCK_IN when backend enters closing or lockin_at exists
  if (battle.state === "closing" || battle.lockin_at) {
    return "LOCK_IN";
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
      if (!battle || battle.state !== "active" || !participant || !arena) {
        console.log("[Vote] Blocked - battle not active or missing data");
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
    [battle, participant, voteRecord],
  );

  const arenaId = location.state?.arenaId as string | undefined;
  const roleIntent = location.state?.role_intent as "host" | "participant" | undefined;

  const { hasJustResolved, lastWinnerSide, isDraw, acknowledgeResult } = useArenaFlow(arenaId ?? "", closureState);

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
          .select("id, name, state")
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

  // Voting enabled exclusively by backend state
  const isVotingEnabled = battle?.state === "active";

  // Check if user has already voted in sudden death (vote_type === 'sudden_death')
  const hasSuddenDeathVote = voteRecord?.vote_type === "sudden_death";

  return (
    <div className="relative min-h-dvh w-full">
      {/* Presentational layer */}
      <StageView
        arena={arena!}
        battle={battle}
        participant={participant!}
        currentVote={voteRecord}
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
