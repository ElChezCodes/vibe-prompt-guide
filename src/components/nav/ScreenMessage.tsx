import { useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";

interface ScreenMessageProps {
  message: string;
  isError?: boolean;
  // Venue screens (Stage View) have nobody to tap a button
  showHomeButton?: boolean;
}

// Full-screen message with a way out, so no error is a dead end
const ScreenMessage = ({ message, isError = false, showHomeButton = true }: ScreenMessageProps) => {
  const navigate = useNavigate();

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center space-bg px-6">
      <div className="neon-panel rounded-2xl px-8 py-7 flex flex-col items-center gap-5 max-w-sm w-full animate-fade-in">
        <p className={`text-center ${isError ? "text-destructive font-medium" : "text-text-secondary"}`}>{message}</p>
        {showHomeButton && (
          <Button variant="neon" className="w-full" onClick={() => navigate("/")}>
            Back to start
          </Button>
        )}
      </div>
    </div>
  );
};

export default ScreenMessage;
