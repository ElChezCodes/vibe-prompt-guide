import { useEffect, useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";
import ProposeSongPanel from "@/components/battle/ProposeSongPanel";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { useArenaFromRoute } from "@/hooks/useArenaFromRoute";
import { getOwnParticipant } from "@/integrations/supabase/participants";
import { arenaPath } from "@/lib/arenaRoutes";

// Proponer outside the battle. Same panel (and backend state) as the Battle
// Room modal. Proposing needs membership, which is only gained by entering the
// Battle Room, so non-members (or members who left) are sent there first.
const ProposeSongScreen = () => {
  const navigate = useNavigate();
  const { code, arena, status } = useArenaFromRoute();
  const [membership, setMembership] = useState<"loading" | "member" | "not_member">("loading");

  useEffect(() => {
    if (!arena) return;
    getOwnParticipant(arena.id)
      .then((p) => setMembership(p && !p.left_at ? "member" : "not_member"))
      .catch(() => setMembership("not_member"));
  }, [arena]);

  if (status === "not_found") return <ScreenMessage message="Arena not found" isError />;
  if (status === "error") return <ScreenMessage message="Failed to load arena" isError />;
  if (status === "loading" || (arena && arena.state !== "finished" && membership === "loading")) {
    return <ScreenMessage message="Loading..." showHomeButton={false} />;
  }
  if (arena.state === "finished") return <ScreenMessage message="This arena has ended" />;
  if (membership === "not_member") return <Navigate to={arenaPath(code, "battle")} replace />;

  return (
    <div className="h-[calc(100dvh-4rem)] w-full flex flex-col gap-4 px-6 py-8 max-w-md mx-auto">
      <div className="flex-shrink-0">
        <h1 className="text-2xl font-bold text-foreground">Propose a Song</h1>
        <p className="text-sm text-muted-foreground">{arena.name}</p>
      </div>

      <div className="flex-1 min-h-0">
        <ProposeSongPanel arenaId={arena.id} />
      </div>

      <Button variant="outline" className="flex-shrink-0" onClick={() => navigate(arenaPath(code, "battle"))}>
        Back to the battle
      </Button>
    </div>
  );
};

export default ProposeSongScreen;
