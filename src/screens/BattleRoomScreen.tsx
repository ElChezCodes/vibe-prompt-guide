import { useState, useEffect, useRef, useCallback } from "react";
import { Link, useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";
import { QrCode } from "lucide-react";

type ScreenState = 'loading' | 'error' | 'ready';

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
  const timerRef = useRef<NodeJS.Timeout | null>(null);
  const isTransitioningRef = useRef(false);

  const arenaId = location.state?.arenaId as string | undefined;

  const endBattle = useCallback(async (battleId: string) => {
    if (isTransitioningRef.current) return;
    isTransitioningRef.current = true;

    const { data: updatedBattle, error } = await supabase
      .from('battles')
      .update({
        state: 'finished',
        ended_at: new Date().toISOString()
      })
      .eq('id', battleId)
      .eq('state', 'active')
      .select('id, state')
      .maybeSingle();

    if (error) {
      console.error('Failed to end battle:', error);
    }

    if (updatedBattle) {
      setBattle(updatedBattle);
    }

    isTransitioningRef.current = false;
  }, []);

  const startBattle = useCallback(async (battleId: string) => {
    if (isTransitioningRef.current) return;
    isTransitioningRef.current = true;

    const { data: updatedBattle, error } = await supabase
      .from('battles')
      .update({
        state: 'active',
        started_at: new Date().toISOString()
      })
      .eq('id', battleId)
      .eq('state', 'pending')
      .select('id, state')
      .maybeSingle();

    if (error) {
      console.error('Failed to start battle:', error);
      isTransitioningRef.current = false;
      return;
    }

    if (updatedBattle) {
      setBattle(updatedBattle);
      timerRef.current = setTimeout(() => {
        endBattle(battleId);
      }, BATTLE_DURATION_MS);
    }

    isTransitioningRef.current = false;
  }, [endBattle]);

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
          startBattle(currentBattle.id);
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
  }, [arenaId, startBattle]);

  // Loading state
  if (screenState === 'loading') {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-muted-foreground">Loading...</p>
      </div>
    );
  }

  // Error state
  if (screenState === 'error') {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-destructive">{errorMessage}</p>
      </div>
    );
  }

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-4">
      <h1 className="text-2xl font-bold text-foreground mb-2">
        {arena?.name}
      </h1>
      <p className="text-sm text-muted-foreground mb-8">
        Status: {arena?.state}
      </p>
      {battle ? (
        <div className="text-center">
          <p className="text-foreground font-medium">
            {battle.state === 'pending' ? 'Waiting for songs to be proposed' : 'Battle in progress'}
          </p>
          <p className="text-sm text-muted-foreground">State: {battle.state}</p>
        </div>
      ) : (
        <p className="text-muted-foreground text-center">
          Waiting for the next battle to start
        </p>
      )}

      {participant?.is_host && (
        <Button
          variant="outline"
          asChild
          className="mt-8 border-border/50"
        >
          <Link to="/create" state={{ arenaId }}>
            <QrCode className="w-5 h-5 mr-2" />
            Show Arena QR
          </Link>
        </Button>
      )}
    </div>
  );
};

export default BattleRoomScreen;
