import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { useNavigate } from "react-router-dom";
import { createArena } from "@/integrations/supabase/arenas";

const CreateArenaScreen = () => {
  const navigate = useNavigate();
  const [arenaName, setArenaName] = useState("");
  const [isCreating, setIsCreating] = useState(false);

  const handleCreateArena = async () => {
    setIsCreating(true);
    try {
      const result = await createArena(arenaName);
      console.log('Arena created:', result);
      navigate("/battle", { state: { arenaId: result.id } });
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

        {/* Create Arena Button */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "100ms" }}
        >
          <Button
            onClick={handleCreateArena}
            disabled={isCreating}
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
