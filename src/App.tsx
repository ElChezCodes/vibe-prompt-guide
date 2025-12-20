import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import SplashScreen from "./screens/SplashScreen";
import JoinArenaScreen from "./screens/JoinArenaScreen";
import BattleRoomScreen from "./screens/BattleRoomScreen";
import StageViewScreen from "./screens/StageViewScreen";

const queryClient = new QueryClient();

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Toaster />
      <Sonner />
      <BrowserRouter>
        <Routes>
          {/* Linear flow: Splash → Join → Battle */}
          <Route path="/" element={<SplashScreen />} />
          <Route path="/join" element={<JoinArenaScreen />} />
          <Route path="/battle" element={<BattleRoomScreen />} />
          {/* Stage view for venue displays */}
          <Route path="/stage" element={<StageViewScreen />} />
        </Routes>
      </BrowserRouter>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
