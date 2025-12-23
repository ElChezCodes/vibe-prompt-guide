import { useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import {
  InputOTP,
  InputOTPGroup,
  InputOTPSlot,
  InputOTPSeparator,
} from "@/components/ui/input-otp";

const JoinArenaScreen = () => {
  const [code, setCode] = useState("");
  const isCodeComplete = code.length === 6;

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-6">
      <div className="flex flex-col items-center gap-8 max-w-sm w-full">
        {/* Title */}
        <div className="flex flex-col items-center gap-2 animate-fade-in-up">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            Join an Arena
          </h1>
          <p className="text-text-secondary text-sm text-center">
            Enter the 6-digit code to join
          </p>
        </div>

        {/* Arena Code Input */}
        <div className="animate-fade-in-up" style={{ animationDelay: "100ms" }}>
          <InputOTP
            maxLength={6}
            value={code}
            onChange={setCode}
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
            asChild={isCodeComplete}
            size="lg"
            className="w-full text-base font-semibold"
            disabled={!isCodeComplete}
          >
            {isCodeComplete ? (
              <Link to="/battle">Enter Arena</Link>
            ) : (
              <span>Enter Arena</span>
            )}
          </Button>
        </div>

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
