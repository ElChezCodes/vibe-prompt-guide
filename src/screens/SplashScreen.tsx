import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { Music2, Swords } from "lucide-react";
import { Button } from "@/components/ui/button";
import { supabase } from "@/integrations/supabase/client";
import { useCurrentArena } from "@/hooks/useCurrentArena";
import { arenaHomePath } from "@/lib/arenaRoutes";

type RoleIntent = "participant" | "host";

const SplashScreen = () => {
  const navigate = useNavigate();
  const [isLoading, setIsLoading] = useState(false);
  const { data: current } = useCurrentArena();

  const handleAction = async (role: RoleIntent) => {
    setIsLoading(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      
      if (!session) {
        await supabase.auth.signInAnonymously();
      }

      if (role === "participant") {
        navigate("/join", { state: { role_intent: "participant" } });
      } else {
        navigate("/create", { state: { role_intent: "host" } });
      }
    } catch (error) {
      console.error("Auth error:", error);
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="relative min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center px-6 overflow-hidden">
      {/* Neon notes in the corners (static) */}
      <Music2 aria-hidden className="absolute top-8 left-6 w-10 h-10 text-song-a text-glow-a opacity-80" />
      <Music2 aria-hidden className="absolute top-8 right-6 w-10 h-10 text-song-b text-glow-b opacity-80" />

      <div className="flex flex-col items-center gap-8 w-full max-w-xs">
        {/* Logo */}
        <h1 className="font-arcade font-black text-center leading-[0.9] animate-fade-in-up">
          <span className="block text-5xl sm:text-6xl italic tracking-wide logo-music">MUSIC</span>
          <span className="block text-5xl sm:text-6xl italic tracking-wide logo-fighter -mt-1">FIGHTER</span>
        </h1>

        {/* Tagline */}
        <p 
          className="text-text-secondary text-lg text-center animate-fade-in-up"
          style={{ animationDelay: '0.1s', animationFillMode: 'backwards' }}
        >
          Battle your friends with songs
        </p>

        {/* Actions */}
        <div 
          className="flex flex-col gap-3 mt-2 w-full animate-fade-in-up"
          style={{ animationDelay: '0.2s', animationFillMode: 'backwards' }}
        >
          {/* Way back to an arena you're still in (left via "← App", reload, etc.) */}
          {current && (
            <button
              className="neon-panel w-full rounded-xl px-4 py-3 flex items-center gap-3 text-left hover:brightness-125 transition"
              onClick={() => navigate(arenaHomePath(current.arena_code, current.is_host, current.state))}
            >
              <span className="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/15">
                <Swords className="w-5 h-5 text-primary icon-glow-primary" />
              </span>
              <span className="flex-1 min-w-0">
                <span className="block neon-label">Your arena is live</span>
                <span className="block text-base font-semibold text-foreground truncate">Back to {current.name}</span>
              </span>
            </button>
          )}
          <Button 
            size="lg" 
            className="w-full h-12 text-base font-bold"
            onClick={() => handleAction("participant")}
            disabled={isLoading}
          >
            Enter Arena
          </Button>
          <Button 
            size="lg" 
            variant="neon"
            className="w-full h-12 text-base font-semibold"
            onClick={() => handleAction("host")}
            disabled={isLoading}
          >
            Create Arena
          </Button>
        </div>
      </div>
    </div>
  );
};

export default SplashScreen;
