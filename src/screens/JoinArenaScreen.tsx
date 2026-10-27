import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
  InputOTPSeparator,
} from "@/components/ui/input-otp";
import { normalizeArenaCode, resolveArenaByCode } from "@/integrations/supabase/arenas";
import { getOrCreateIdentityAnchor } from "@/integrations/supabase/identityAnchors";
import { arenaPath } from "@/lib/arenaRoutes";

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
    <div className="relative min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center bg-background px-6">
      <button
        onClick={() => navigate("/")}
        className="absolute top-4 left-4 p-2 text-muted-foreground hover:text-foreground"
        aria-label="Back"
      >
        <ArrowLeft className="w-5 h-5" />
      </button>
      <div className="flex flex-col items-center gap-8 max-w-sm w-full">
        {/* Title */}
        <div className="flex flex-col items-center gap-2 animate-fade-in-up">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Join an Arena
          </h1>
          <p className="text-text-secondary text-sm text-center">
            Enter the 6-character code to join
          </p>
        </div>

        {/* Arena Code Input */}
        <div className="animate-fade-in-up" style={{ animationDelay: "100ms" }}>
          <InputOTP
            maxLength={6}
            value={code}
            onChange={(value) => setCode(normalizeArenaCode(value))}
            containerClassName="justify-center"
          >
            <InputOTPGroup>
              <InputOTPSlot index={0} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
              <InputOTPSlot index={1} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
              <InputOTPSlot index={2} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
            </InputOTPGroup>
            <InputOTPSeparator className="text-muted-foreground" />
            <InputOTPGroup>
              <InputOTPSlot index={3} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
              <InputOTPSlot index={4} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
              <InputOTPSlot index={5} className="h-14 w-12 text-xl font-bold bg-surface border-border" />
            </InputOTPGroup>
          </InputOTP>
        </div>

        {/* Enter Arena Button */}
        <div className="w-full animate-fade-in-up" style={{ animationDelay: "200ms" }}>
          <Button
            size="lg"
            className="w-full text-base font-semibold"
            disabled={!isCodeComplete || isJoining}
            onClick={handleJoinArena}
          >
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
          Ask the host for the arena code
        </p>
      </div>
    </div>
  );
};

export default JoinArenaScreen;
