import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { QrCode, Swords, Loader2 } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { Arena, getArena, getMoodLabel, startArenaBattles } from "@/integrations/supabase/arenas";

function hashStringToUint32(input: string) {
  let hash = 2166136261;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function qrCellOn(arenaId: string, index: number) {
  return (hashStringToUint32(`${arenaId}:${index}`) % 100) < 50;
}

const ArenaLobbyScreen = () => {
  const location = useLocation();
  const navigate = useNavigate();
  const [isLoading, setIsLoading] = useState(false);
  const [arena, setArena] = useState<Arena | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  
  const arenaId = location.state?.arenaId as string | undefined;
  const arenaName = arena?.name ?? (location.state?.arenaName as string | undefined);

  useEffect(() => {
    if (!arenaId) return;
    getArena(arenaId)
      .then(setArena)
      .catch(() => setErrorMessage("Failed to load arena"));
  }, [arenaId]);

  // Join resolves against arenas.arena_code, so display exactly that
  const arenaCode = arena?.arena_code
    ? arena.arena_code.replace(/(.{3})(.{3})/, '$1 $2')
    : '';
  const moodLabel = getMoodLabel(arena?.mood);
  const isClosed = arena?.state === "finished" || arena?.state === "expired";

  const handleEnterBattle = async () => {
    if (!arenaId || !arena || isClosed || isLoading) return;
    
    setIsLoading(true);
    setErrorMessage("");
    
    try {
      // Backend transition waiting -> active; battles can't be created before it
      if (arena.state === "waiting") {
        await startArenaBattles(arenaId);
      }

      const { data, error } = await supabase.functions.invoke('create-battle', {
        body: { arena_id: arenaId }
      });

      if (error) {
        console.error('Failed to create battle:', error);
        setErrorMessage("Failed to start battles");
        return;
      }

      if (!data?.battle_id) {
        console.error('No battle_id returned from create-battle');
        return;
      }

      navigate("/battle", { 
        state: { 
          arenaId, 
          battleId: data.battle_id,
          role_intent: "host" 
        } 
      });
    } catch (err) {
      console.error('Error starting battles:', err);
      setErrorMessage("Failed to start battles");
    } finally {
      setIsLoading(false);
    }
  };

  if (!arenaId) {
    return (
      <div className="min-h-dvh w-full flex items-center justify-center bg-background">
        <p className="text-destructive">No arena data</p>
      </div>
    );
  }

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-6 py-12">
      <div className="w-full max-w-md flex flex-col items-center gap-8">
        {/* Header */}
        <div className="text-center animate-fade-in-up">
          <h1 className="text-3xl md:text-4xl font-bold text-foreground mb-2">
            {arenaName || "Arena Created"}
          </h1>
          {moodLabel && (
            <p className="inline-block mb-2 px-3 py-1 rounded-full bg-primary/15 text-sm text-foreground">
              {moodLabel}
            </p>
          )}
          <p className="text-muted-foreground">
            {isClosed ? "This arena has ended" : "Share the code with your guests"}
          </p>
        </div>

        {/* Arena Code Block */}
        <div 
          className="w-full bg-surface rounded-xl border border-border/50 p-6 text-center animate-fade-in-up"
          style={{ animationDelay: "50ms" }}
        >
          <p className="text-sm text-muted-foreground mb-3">Arena Code</p>
          <p className="text-4xl md:text-5xl font-bold text-foreground tracking-[0.3em] font-mono">
            {arenaCode}
          </p>
        </div>

        {/* QR Code Block */}
        <div 
          className="bg-surface rounded-xl border border-border/50 p-6 text-center animate-fade-in-up"
          style={{ animationDelay: "100ms" }}
        >
          <p className="text-sm text-muted-foreground mb-4">Scan to join</p>
          <div className="w-48 h-48 mx-auto bg-white rounded-lg flex items-center justify-center">
            <div className="w-40 h-40 relative">
              <QrCode className="w-full h-full text-background" strokeWidth={0.5} />
              <div className="absolute inset-4 grid grid-cols-7 grid-rows-7 gap-1">
                {Array.from({ length: 49 }).map((_, i) => {
                  const on = qrCellOn(arenaId, i);
                  return (
                    <div
                      key={i}
                      className={`rounded-sm ${on ? "bg-background" : "bg-transparent"}`}
                    />
                  );
                })}
              </div>
            </div>
          </div>
        </div>

        {/* Next Steps Guidance */}
        <div 
          className="w-full bg-surface/50 rounded-xl border border-border/30 p-5 animate-fade-in-up"
          style={{ animationDelay: "150ms" }}
        >
          <p className="text-sm font-medium text-foreground mb-3">Next steps</p>
          <ul className="space-y-2 text-sm text-muted-foreground">
            <li className="flex items-start gap-2">
              <span className="text-primary">•</span>
              Ask guests to join using the code or QR
            </li>
            <li className="flex items-start gap-2">
              <span className="text-primary">•</span>
              Display the Stage View on the venue screen
            </li>
            <li className="flex items-start gap-2">
              <span className="text-primary">•</span>
              Connect your music account to start battles
            </li>
          </ul>
        </div>

        {/* Primary Action - Enter Battle */}
        {errorMessage && (
          <p className="text-sm text-destructive">{errorMessage}</p>
        )}

        <Button
          onClick={handleEnterBattle}
          disabled={isLoading || !arena || isClosed}
          className="w-full h-12 text-lg font-semibold animate-fade-in-up"
          style={{ animationDelay: "200ms" }}
        >
          {isLoading ? (
            <Loader2 className="w-5 h-5 mr-2 animate-spin" />
          ) : (
            <Swords className="w-5 h-5 mr-2" />
          )}
          {isLoading ? "Creating Battle..." : arena?.state === "waiting" ? "Start Battles" : "Enter Battle"}
        </Button>
      </div>
    </div>
  );
};

export default ArenaLobbyScreen;
