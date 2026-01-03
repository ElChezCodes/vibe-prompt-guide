import { useState, useEffect, useCallback } from "react";
import { useLocation } from "react-router-dom";
import { supabase } from "@/integrations/supabase/client";
import { Button } from "@/components/ui/button";

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

const BattleRoomScreen = () => {
  const location = useLocation();
  const [screenState, setScreenState] = useState<ScreenState>('loading');
  const [errorMessage, setErrorMessage] = useState<string>('');
  const [arena, setArena] = useState<ArenaData | null>(null);
  const [participant, setParticipant] = useState<ParticipantData | null>(null);
  const [battle, setBattle] = useState<BattleData | null>(null);
  const [isCreatingBattle, setIsCreatingBattle] = useState(false);

  const arenaId = location.state?.arenaId as string | undefined;

  const fetchBattle = useCallback(async (arenaIdToFetch: string) => {
    const { data: battleData, error: battleError } = await supabase
      .from('battles')
      .select('id, state')
      .eq('arena_id', arenaIdToFetch)
      .maybeSingle();

    if (battleError) {
      console.error('Failed to fetch battle:', battleError);
    }

    return battleData;
  }, []);

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

        const battleData = await fetchBattle(arenaId);

        setArena(arenaData);
        setParticipant(participantData);
        setBattle(battleData);
        setScreenState('ready');
      } catch (err) {
        console.error('Battle room load error:', err);
        setErrorMessage('Failed to load battle room');
        setScreenState('error');
      }
    };

    loadBattleRoom();
  }, [arenaId, fetchBattle]);

  const handleCreateBattle = async () => {
    if (!arenaId || !participant?.is_host || isCreatingBattle) return;

    setIsCreatingBattle(true);

    try {
      const existingBattle = await fetchBattle(arenaId);
      if (existingBattle) {
        setBattle(existingBattle);
        setIsCreatingBattle(false);
        return;
      }

      const { error: insertError } = await supabase
        .from('battles')
        .insert({
          arena_id: arenaId,
          state: 'pending',
          started_at: null,
        });

      if (insertError) {
        console.error('Failed to create battle:', insertError);
        setIsCreatingBattle(false);
        return;
      }

      const newBattle = await fetchBattle(arenaId);
      setBattle(newBattle);
    } catch (err) {
      console.error('Create battle error:', err);
    } finally {
      setIsCreatingBattle(false);
    }
  };

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
          {battle.state === 'pending' ? (
            <p className="text-muted-foreground">Waiting for songs to be proposed</p>
          ) : (
            <>
              <p className="text-foreground font-medium">Battle in progress</p>
              <p className="text-sm text-muted-foreground">State: {battle.state}</p>
            </>
          )}
        </div>
      ) : participant?.is_host ? (
        <Button
          onClick={handleCreateBattle}
          disabled={isCreatingBattle}
        >
          {isCreatingBattle ? 'Creating...' : 'Create Battle'}
        </Button>
      ) : (
        <p className="text-muted-foreground text-center">
          Waiting for the next battle to start
        </p>
      )}
    </div>
  );
};

export default BattleRoomScreen;
