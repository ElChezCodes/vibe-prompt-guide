import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import SplashScreen from "./screens/SplashScreen";
import JoinArenaScreen from "./screens/JoinArenaScreen";
import BattleRoomScreen from "./screens/BattleRoomScreen";
import StageViewScreen from "./screens/StageViewScreen";
import CreateArenaScreen from "./screens/CreateArenaScreen";
import ArenaLobbyScreen from "./screens/ArenaLobbyScreen";
import ConnectStreamingScreen from "./screens/ConnectStreamingScreen";
import ProposeSongScreen from "./screens/ProposeSongScreen";
import RankingScreen from "./screens/RankingScreen";
import ProfileScreen from "./screens/ProfileScreen";
import AppShell from "./components/nav/AppShell";
import { useAnonymousAuth } from "./hooks/useAnonymousAuth";

const queryClient = new QueryClient();

const AppRoutes = () => {
  const { isReady } = useAnonymousAuth();

  if (!isReady) {
    return null;
  }

  return (
    <Routes>
      {/* App zone: bottom tab bar (Home · Propose · Arena · Ranking · Profile) */}
      <Route element={<AppShell />}>
        <Route path="/" element={<SplashScreen />} />
        <Route path="/join" element={<JoinArenaScreen />} />
        {/* What the lobby QR encodes */}
        <Route path="/join/:code" element={<JoinArenaScreen />} />
        <Route path="/create" element={<CreateArenaScreen />} />
        <Route path="/ranking" element={<RankingScreen />} />
        <Route path="/profile" element={<ProfileScreen />} />
        {/* Arena screens: the arena travels in the URL */}
        <Route path="/a/:code/lobby" element={<ArenaLobbyScreen />} />
        <Route path="/a/:code/connect" element={<ConnectStreamingScreen />} />
        <Route path="/a/:code/propose" element={<ProposeSongScreen />} />
      </Route>

      {/* Battle Room: no tab bar or menus inside the battle (Paso_2 §3) */}
      <Route path="/a/:code/battle" element={<BattleRoomScreen />} />
      {/* Stage view for venue displays, opened from a shared link */}
      <Route path="/a/:code/stage" element={<StageViewScreen />} />

      {/* Old state-only routes (/battle, /lobby, /stage, /connect) and anything unknown */}
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
};

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Toaster />
      <Sonner />
      <BrowserRouter>
        <AppRoutes />
      </BrowserRouter>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
