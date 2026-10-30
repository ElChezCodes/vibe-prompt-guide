import { Navigate, useNavigate } from "react-router-dom";
import BackButton from "@/components/nav/BackButton";
import ScreenMessage from "@/components/nav/ScreenMessage";
import SpotifyConnectionPanel from "@/components/streaming/SpotifyConnectionPanel";
import SpotifyScreenState from "@/components/streaming/SpotifyScreenState";
import { useArenaFromRoute } from "@/hooks/useArenaFromRoute";
import { arenaPath } from "@/lib/arenaRoutes";

// Host only, reached from the lobby. The connection belongs to the host (not
// the arena) and is reused by all their arenas (step 5).
const ConnectStreamingScreen = () => {
  const navigate = useNavigate();
  const { code, isHost, status } = useArenaFromRoute();

  if (status === "loading") return <SpotifyScreenState message="Loading..." />;
  if (status === "not_found") return <ScreenMessage message="Arena not found" isError />;
  if (status === "error") return <ScreenMessage message="Failed to load arena" isError />;
  if (!isHost) return <Navigate to={arenaPath(code, "battle")} replace />;

  const lobbyPath = arenaPath(code, "lobby");

  return (
    <div className="relative min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center px-4 pt-20 pb-12">
      <BackButton onClick={() => navigate(lobbyPath)} label="Lobby" />
      <div className="w-full max-w-md flex flex-col gap-6">
        <div className="text-center space-y-2 animate-fade-in-up">
          <h1 className="neon-heading text-2xl leading-snug">Your Spotify</h1>
          <p className="text-text-secondary text-sm">Music plays from your Spotify app, on your own device.</p>
        </div>
        <div className="neon-panel rounded-2xl p-4 sm:p-5 animate-fade-in-up" style={{ animationDelay: "50ms" }}>
          <SpotifyConnectionPanel returnTo={arenaPath(code, "connect")} />
        </div>
      </div>
    </div>
  );
};

export default ConnectStreamingScreen;
