import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { useNavigate } from "react-router-dom";
import { createArena, ARENA_MOODS, ArenaMood } from "@/integrations/supabase/arenas";

const MOOD_GROUPS = Array.from(new Set(ARENA_MOODS.map((m) => m.group)));

const CreateArenaScreen = () => {
  const navigate = useNavigate();
  const [arenaName, setArenaName] = useState("");
  const [mood, setMood] = useState<ArenaMood | null>(null);
  const [isCreating, setIsCreating] = useState(false);

  const handleCreateArena = async () => {
    if (!mood) return;
    setIsCreating(true);
    try {
      const result = await createArena(arenaName, mood);
      console.log('Arena created:', result);
      navigate("/lobby", { state: { arenaId: result.id, arenaName: result.name } });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error('Failed to create arena:', message, error);
      setIsCreating(false);
    }
  };

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-6 py-12">
      <div className="w-full max-w-md flex flex-col items-center gap-8">
        {/* Header */}
        <div className="text-center animate-fade-in-up">
          <h1 className="text-3xl md:text-4xl font-bold text-foreground mb-2">
            Create Arena
          </h1>
          <p className="text-muted-foreground">
            Set up your Music Fighter session
          </p>
        </div>

        {/* Arena Name Input */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "50ms" }}
        >
          <Input
            type="text"
            placeholder="Arena name (optional)"
            value={arenaName}
            onChange={(e) => setArenaName(e.target.value)}
            disabled={isCreating}
            className="w-full h-12 text-center text-lg bg-surface border-border/50 focus:border-primary/50"
          />
        </div>

        {/* Mood - required, fixed for the arena's lifetime */}
        <div
          className="w-full animate-fade-in-up"
          style={{ animationDelay: "75ms" }}
        >
          <p className="text-sm text-muted-foreground text-center mb-3">
            Pick the mood
          </p>
          <div className="max-h-72 overflow-y-auto pr-1 space-y-4">
            {MOOD_GROUPS.map((group) => (
              <div key={group}>
                <p className="text-xs uppercase tracking-wider text-muted-foreground/70 mb-2">
                  {group}
                </p>
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {ARENA_MOODS.filter((m) => m.group === group).map((m) => (
                    <button
                      key={m.value}
                      type="button"
                      onClick={() => setMood(m.value)}
                      disabled={isCreating}
                      aria-pressed={mood === m.value}
                      className={`h-11 rounded-lg border text-sm font-medium transition-colors ${
                        mood === m.value
                          ? "border-primary bg-primary/15 text-foreground"
                          : "border-border/50 bg-surface text-muted-foreground hover:border-primary/40"
                      }`}
                    >
                      {m.emoji} {m.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Create Arena Button */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "100ms" }}
        >
          <Button
            onClick={handleCreateArena}
            disabled={isCreating || !mood}
            className="w-full h-12 text-lg font-semibold"
          >
            {isCreating ? "Creating..." : "Create Arena"}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default CreateArenaScreen;
