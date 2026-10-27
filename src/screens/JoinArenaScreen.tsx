import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
  InputOTPSeparator,
} from "@/components/ui/input-otp";
import BackButton from "@/components/nav/BackButton";
import { normalizeArenaCode, resolveArenaByCode } from "@/integrations/supabase/arenas";
import { getOrCreateIdentityAnchor } from "@/integrations/supabase/identityAnchors";
import { arenaPath } from "@/lib/arenaRoutes";

const SLOT_CLASS =
  "h-14 w-12 text-xl font-bold font-mono bg-card/80 border-song-a/40 text-foreground";

const JoinArenaScreen = () => {
  const navigate = useNavigate();
  // /join/:code is what the lobby QR encodes: prefilled, joins straight away
  const { code: codeParam } = useParams();
  const [code, setCode] = useState(() => normalizeArenaCode(codeParam ?? ""));
  const autoJoinedRef = useRef(false);
  const [isJoining, setIsJoining] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");

  const isCodeComplete = code.length === 6;

  const handleJoinArena = async () => {
    if (!isCodeComplete || isJoining) return;
    autoJoinedRef.current = true;

    setIsJoining(true);
    setErrorMessage("");

    try {
      await resolveArenaByCode(code);
      await getOrCreateIdentityAnchor();

      // Participant registration happens in the Battle Room (host-ness from arenas.host_id)
      // replace: back from the battle must not re-trigger the /join/:code auto-join
      navigate(arenaPath(code, "battle"), { replace: true });
    } catch (error) {
      console.error('Failed to join arena:', error);
      setErrorMessage(error instanceof Error ? error.message : "Failed to join arena");
      setIsJoining(false);
    }
  };


  useEffect(() => {
    if (codeParam && isCodeComplete && !autoJoinedRef.current) handleJoinArena();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [codeParam]);

  return (
    <div className="relative min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center px-6">
      <BackButton onClick={() => navigate("/")} />
      <div className="flex flex-col items-center gap-8 max-w-sm w-full">
        {/* Title */}
        <div className="flex flex-col items-center gap-2 animate-fade-in-up">
          <h1 className="neon-heading text-2xl text-center">Join Arena</h1>
          <p className="text-text-secondary text-sm text-center">
            Enter the 6-character code to join
          </p>
        </div>

        {/* Arena Code Input */}
        <div
          className="neon-panel rounded-2xl px-4 py-6 w-full flex justify-center animate-fade-in-up"
          style={{ animationDelay: "100ms" }}
        >
          <InputOTP
            maxLength={6}
            value={code}
            onChange={(value) => setCode(normalizeArenaCode(value))}
            containerClassName="justify-center"
          >
            <InputOTPGroup>
              <InputOTPSlot index={0} className={SLOT_CLASS} />
              <InputOTPSlot index={1} className={SLOT_CLASS} />
              <InputOTPSlot index={2} className={SLOT_CLASS} />
            </InputOTPGroup>
            <InputOTPSeparator className="text-song-b" />
            <InputOTPGroup>
              <InputOTPSlot index={3} className={SLOT_CLASS.replace("song-a", "song-b")} />
              <InputOTPSlot index={4} className={SLOT_CLASS.replace("song-a", "song-b")} />
              <InputOTPSlot index={5} className={SLOT_CLASS.replace("song-a", "song-b")} />
            </InputOTPGroup>
          </InputOTP>
        </div>

        {/* Enter Arena Button */}
        <div className="w-full animate-fade-in-up" style={{ animationDelay: "200ms" }}>
          <Button
            size="lg"
            className="w-full h-12 text-base font-bold"
            disabled={!isCodeComplete || isJoining}
            onClick={handleJoinArena}
          >
            {isJoining && <Loader2 className="w-5 h-5 animate-spin" />}
            {isJoining ? "Joining..." : "Enter Arena"}
          </Button>
        </div>

        {errorMessage && (
          <p className="text-sm text-destructive text-center">{errorMessage}</p>
        )}

        {/* Helper Text */}
        <p 
          className="text-muted-foreground text-xs text-center animate-fade-in-up"
          style={{ animationDelay: "300ms" }}
        >
          {isJoining ? "Getting you into the arena..." : "Ask the host for the arena code"}
        </p>
      </div>
    </div>
  );
};

export default JoinArenaScreen;
