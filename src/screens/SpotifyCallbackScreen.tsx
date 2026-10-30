import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Button } from "@/components/ui/button";
import SpotifyScreenState from "@/components/streaming/SpotifyScreenState";
import { completeSpotifyConnect } from "@/integrations/supabase/spotify";

// Spotify's redirect target (registered redirect URI). The Edge Function
// validates state, exchanges the code and says where to send the host back.
const SpotifyCallbackScreen = () => {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const [message, setMessage] = useState("Connecting Spotify...");
  const [failed, setFailed] = useState(false);
  // The code and state are single-use: never send them twice
  const handled = useRef(false);

  useEffect(() => {
    if (handled.current) return;
    handled.current = true;

    completeSpotifyConnect({
      code: params.get("code"),
      state: params.get("state"),
      error: params.get("error"),
    })
      .then((result) => navigate(result.return_to || "/", { replace: true }))
      .catch((err) => {
        setFailed(true);
        setMessage(err instanceof Error ? err.message : "Could not connect Spotify");
      });
  }, [params, navigate]);

  return (
    <SpotifyScreenState message={message} isError={failed}>
      {failed && (
        <Button variant="neon" className="w-full" onClick={() => navigate("/")}>
          Back to start
        </Button>
      )}
    </SpotifyScreenState>
  );
};

export default SpotifyCallbackScreen;
