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
    <div className="min-h-dvh w-full flex flex-col items-center justify-center gap-4 bg-background px-6">
      <p className={isError ? "text-destructive text-center" : "text-muted-foreground text-center"}>{message}</p>
      {showHomeButton && (
        <Button variant="outline" onClick={() => navigate("/")}>
          Back to start
        </Button>
      )}
    </div>
  );
};

export default ScreenMessage;
