import { useState, useEffect, useRef, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import StageView from "@/components/battle/StageView";

type ScreenState = 'loading' | 'error' | 'ready';
type VoteSide = 'A' | 'B' | null;

interface ArenaData {
  id: string;
  name: string;
  state: string;
}

interface ParticipantData {
  id: string;
  is_host: boolean;
}

interface BattleData {
  id: string;
  state: string;
}

const BATTLE_DURATION_MS = 30000;

const BattleRoomScreen = () => {
  const location = useLocation();
  const [screenState, setScreenState] = useState<ScreenState>('loading');
  const [errorMessage, setErrorMessage] = useState<string>('');
  const [arena, setArena] = useState<ArenaData | null>(null);
  const [participant, setParticipant] = useState<ParticipantData | null>(null);
  const [battle, setBattle] = useState<BattleData | null>(null);
  const [currentVote, setCurrentVote] = useState<VoteSide>(null);
  const timerRef = useRef<NodeJS.Timeout | null>(null);
  const isTransitioningRef = useRef(false);

  const handleVote = useCallback((side: 'A' | 'B') => {
    if (!battle || battle.state !== 'active') {
      console.log('[Vote] Blocked - battle not active');
      return;
    }
    console.log(`[Vote] User voted for Song ${side}`);
    setCurrentVote(side);
  }, [battle]);

  const arenaId = location.state?.arenaId as string | undefined;

  const startBattleAndScheduleEnd = useCallback(async (battleId: string) => {
    if (isTransitioningRef.current) return;
    isTransitioningRef.current = true;

    const { error: updateError } = await supabase
      .from('battles')
      .update({
        state: 'active',
        started_at: new Date().toISOString()
      })
      .eq('id', battleId)
      .eq('state', 'pending');

    if (updateError) {
      console.error('Failed to start battle:', updateError);
      isTransitioningRef.current = false;
      return;
    }

    const { data: updatedBattle } = await supabase
      .from('battles')
      .select('id, state')
      .eq('id', battleId)
      .maybeSingle();

    if (updatedBattle) {
      setBattle(updatedBattle);
    }

    isTransitioningRef.current = false;
    return updatedBattle;
  }, []);

  const endBattleAndContinue = useCallback(async (battleId: string) => {
    if (isTransitioningRef.current) return;
    isTransitioningRef.current = true;

    const { error: updateError } = await supabase
      .from('battles')
      .update({
        state: 'finished',
        ended_at: new Date().toISOString()
      })
      .eq('id', battleId)
      .eq('state', 'active');

    if (updateError) {
      console.error('Failed to end battle:', updateError);
      isTransitioningRef.current = false;
      return;
    }

    const { data: updatedBattle } = await supabase
      .from('battles')
      .select('id, state')
      .eq('id', battleId)
      .maybeSingle();

    if (updatedBattle) {
      setBattle(updatedBattle);
    }

    isTransitioningRef.current = false;

    // Query for next pending battle
    const { data: nextPending } = await supabase
      .from('battles')
      .select('id, state')
      .eq('arena_id', arenaId!)
      .eq('state', 'pending')
      .order('created_at', { ascending: true })
      .limit(1)
      .maybeSingle();

    if (nextPending) {
      const started = await startBattleAndScheduleEnd(nextPending.id);
      if (started) {
        timerRef.current = setTimeout(() => {
          endBattleAndContinue(nextPending.id);
        }, BATTLE_DURATION_MS);
      }
    } else {
      // Create a new pending battle and start it
      const { data: newBattle } = await supabase
        .from('battles')
        .insert({
          arena_id: arenaId,
          song_a_id: '00000000-0000-0000-0000-000000000000',
          song_b_id: '00000000-0000-0000-0000-000000000000',
          started_at: null
        })
        .select('id, state')
        .single();

      if (newBattle) {
        const started = await startBattleAndScheduleEnd(newBattle.id);
        if (started) {
          timerRef.current = setTimeout(() => {
            endBattleAndContinue(newBattle.id);
          }, BATTLE_DURATION_MS);
        }
      }
    }
  }, [arenaId, startBattleAndScheduleEnd]);

  useEffect(() => {
    const loadBattleRoom = async () => {
      try {
        if (!arenaId) {
          setErrorMessage('No arena ID provided');
          setScreenState('error');
          return;
        }

        const identityAnchorId = localStorage.getItem('identity_anchor_id');
        if (!identityAnchorId) {
          setErrorMessage('No identity found');
          setScreenState('error');
          return;
        }

        const { data: arenaData, error: arenaError } = await supabase
          .from('arenas')
          .select('id, name, state')
          .eq('id', arenaId)
          .single();

        if (arenaError || !arenaData) {
          console.error('Failed to fetch arena:', arenaError);
          setErrorMessage('Arena not found');
          setScreenState('error');
          return;
        }

        const { data: participantData, error: participantError } = await supabase
          .from('participants')
          .select('id, is_host')
          .eq('arena_id', arenaId)
          .eq('identity_anchor_id', identityAnchorId)
          .single();

        if (participantError || !participantData) {
          console.error('Failed to fetch participant:', participantError);
          setErrorMessage('Not a participant');
          setScreenState('error');
          return;
        }

        const { data: existingBattle, error: battleError } = await supabase
          .from('battles')
          .select('id, state')
          .eq('arena_id', arenaId)
          .in('state', ['pending', 'active'])
          .maybeSingle();

        if (battleError) {
          console.error('Failed to fetch battle:', battleError);
        }

        let currentBattle = existingBattle;

        if (!currentBattle) {
          const { data: newBattle, error: insertError } = await supabase
            .from('battles')
            .insert({
              arena_id: arenaId,
              song_a_id: '00000000-0000-0000-0000-000000000000',
              song_b_id: '00000000-0000-0000-0000-000000000000',
              started_at: null
            })
            .select('id, state')
            .single();

          if (insertError) {
            console.error('Failed to create battle:', insertError);
          } else {
            currentBattle = newBattle;
          }
        }

        setArena(arenaData);
        setParticipant(participantData);
        setBattle(currentBattle);
        setScreenState('ready');

        if (currentBattle?.state === 'pending') {
          const started = await startBattleAndScheduleEnd(currentBattle.id);
          if (started) {
            timerRef.current = setTimeout(() => {
              endBattleAndContinue(currentBattle.id);
            }, BATTLE_DURATION_MS);
          }
        }
      } catch (err) {
        console.error('Battle room load error:', err);
        setErrorMessage('Failed to load battle room');
        setScreenState('error');
      }
    };

    loadBattleRoom();

    return () => {
      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }
    };
  }, [arenaId, startBattleAndScheduleEnd, endBattleAndContinue]);

  if (screenState === 'loading') {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-muted-foreground">Loading...</p>
      </div>
    );
  }

  if (screenState === 'error') {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-destructive">{errorMessage}</p>
      </div>
    );
  }

  const isVotingEnabled = battle?.state === 'active';

  return (
    <div className="relative min-h-dvh w-full">
      {/* Presentational layer */}
      <StageView 
        arena={arena!} 
        battle={battle} 
        participant={participant!}
        currentVote={currentVote}
      />

      {/* Invisible interaction layer - positioned above StageView */}
      {isVotingEnabled && (
        <div className="absolute inset-0 z-50 pointer-events-none">
          {/* Match the layout of StageView's battle arena section */}
          <div className="min-h-dvh w-full flex flex-col">
            {/* Spacer for tension bar + timer */}
            <div className="pt-8 px-8"><div className="h-3" /></div>
            <div className="py-8"><div className="h-16 lg:h-24" /></div>

            {/* Clickable song areas */}
            <div className="flex-1 flex items-center justify-center px-8 lg:px-16">
              <div className="w-full max-w-7xl flex items-center justify-center gap-8 lg:gap-16">
                {/* Song A hit area */}
                <div 
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote('A')}
                  role="button"
                  aria-label="Vote for Song A"
                />

                {/* VS spacer */}
                <div className="flex-shrink-0 w-16 lg:w-24" />

                {/* Song B hit area */}
                <div 
                  className="flex-1 max-w-md aspect-square pointer-events-auto cursor-pointer"
                  onClick={() => handleVote('B')}
                  role="button"
                  aria-label="Vote for Song B"
                />
              </div>
            </div>

            <div className="h-16 lg:h-24" />
          </div>
        </div>
      )}
    </div>
  );
};

export default BattleRoomScreen;
