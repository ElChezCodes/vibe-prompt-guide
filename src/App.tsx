import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import SplashScreen from "./screens/SplashScreen";
import JoinArenaScreen from "./screens/JoinArenaScreen";
import BattleRoomScreen from "./screens/BattleRoomScreen";
import StageViewScreen from "./screens/StageViewScreen";
import CreateArenaScreen from "./screens/CreateArenaScreen";
import ArenaLobbyScreen from "./screens/ArenaLobbyScreen";
import ConnectStreamingScreen from "./screens/ConnectStreamingScreen";
import { useAnonymousAuth } from "./hooks/useAnonymousAuth";

const queryClient = new QueryClient();

const AppRoutes = () => {
  const { isReady } = useAnonymousAuth();

  if (!isReady) {
    return null;
  }

  return (
    <Routes>
      {/* Linear flow: Splash → Join → Battle */}
      <Route path="/" element={<SplashScreen />} />
      <Route path="/join" element={<JoinArenaScreen />} />
      <Route path="/battle" element={<BattleRoomScreen />} />
      {/* Stage view for venue displays */}
      <Route path="/stage" element={<StageViewScreen />} />
      {/* Host create arena */}
      <Route path="/create" element={<CreateArenaScreen />} />
      {/* Host arena lobby with QR/code */}
      <Route path="/lobby" element={<ArenaLobbyScreen />} />
      {/* Host connect streaming */}
      <Route path="/connect" element={<ConnectStreamingScreen />} />
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
