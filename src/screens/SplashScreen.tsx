import { useState } from "react";
import { useNavigate } from "react-router-dom";
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
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center bg-background px-6">
      <div className="flex flex-col items-center gap-8">
        {/* Logo */}
        <h1 
          className="font-arcade text-4xl sm:text-5xl text-primary tracking-wider text-center animate-fade-in-up"
        >
          MUSIC FIGHTER
        </h1>

        {/* Tagline */}
        <p 
          className="text-text-secondary text-lg text-center max-w-xs animate-fade-in-up"
          style={{ animationDelay: '0.1s', animationFillMode: 'backwards' }}
        >
          Battle your friends with songs
        </p>

        {/* Actions */}
        <div 
          className="flex flex-col gap-3 mt-4 w-full max-w-xs animate-fade-in-up"
          style={{ animationDelay: '0.2s', animationFillMode: 'backwards' }}
        >
          {/* Way back to an arena you're still in (left via "← App", reload, etc.) */}
          {current && (
            <Button
              size="lg"
              variant="secondary"
              className="w-full"
              onClick={() => navigate(arenaHomePath(current.arena_code, current.is_host, current.state))}
            >
              Back to {current.name}
            </Button>
          )}
          <Button 
            size="lg" 
            className="w-full"
            onClick={() => handleAction("participant")}
            disabled={isLoading}
          >
            Enter Arena
          </Button>
          <Button 
            size="lg" 
            variant="outline"
            className="w-full"
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
