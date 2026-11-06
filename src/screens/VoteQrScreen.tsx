import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { toast } from "sonner";
import ScreenMessage from "@/components/nav/ScreenMessage";
import { arenaPath } from "@/lib/arenaRoutes";
import { resolveVoteQr, voteFromQr, VoteQrStatus } from "@/integrations/supabase/votes";

const STATUS_NOTICES: Partial<Record<VoteQrStatus, string>> = {
  over: "That round is over: vote in this one",
  locked: "Votes are locked right now",
  paused: "Votes are locked right now",
};

/**
 * /v/:token/:side, what a card's QR on the Stage View encodes. It works with
 * the session this browser already has (so a guest with MF open keeps their
 * identity) and ends in the Battle Room, where they stay as a normal
 * participant with their vote marked. Never votes for a song other than the
 * QR's: the backend says what the token means now.
 */
const VoteQrScreen = () => {
  const { token = "", side = "" } = useParams();
  const navigate = useNavigate();
  const [failed, setFailed] = useState("");
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;

    (async () => {
      try {
        const target = await resolveVoteQr(token, side);
        if (target.status === "invalid") {
          setFailed("This QR isn't valid any more");
          return;
        }
        if (target.status === "finished") {
          toast("This arena has finished");
          navigate("/", { replace: true });
          return;
        }
        const notice =
          target.status === "open" || target.status === "sudden_death"
            ? await voteFromQr(target)
            : STATUS_NOTICES[target.status];
        if (notice) toast(notice);
        // Replace: back must not vote again
        navigate(arenaPath(target.arena_code, "battle"), { replace: true });
      } catch (error) {
        console.error("Failed to vote from QR:", error);
        setFailed("Couldn't read that QR: try again");
      }
    })();
  }, [token, side, navigate]);

  return failed ? <ScreenMessage message={failed} isError /> : <ScreenMessage message="Saving your vote..." showHomeButton={false} />;
};

export default VoteQrScreen;
