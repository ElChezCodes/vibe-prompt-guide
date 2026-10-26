import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Music, Check, AlertCircle, ChevronRight } from "lucide-react";
import { Link } from "react-router-dom";

type ConnectionState = "not_connected" | "connected" | "error";

interface Provider {
  id: string;
  name: string;
  enabled: boolean;
  icon: React.ReactNode;
}

const providers: Provider[] = [
  {
    id: "spotify",
    name: "Spotify",
    enabled: true,
    icon: <Music className="w-5 h-5" />,
  },
  {
    id: "apple",
    name: "Apple Music",
    enabled: false,
    icon: <Music className="w-5 h-5" />,
  },
  {
    id: "other",
    name: "Other providers",
    enabled: false,
    icon: <Music className="w-5 h-5" />,
  },
];

const ConnectStreamingScreen = () => {
  const [connectionState, setConnectionState] = useState<ConnectionState>("not_connected");

  const handleConnect = () => {
    // Mock connection - in real app this would trigger OAuth
    setConnectionState("connected");
  };

  const handleDisconnect = () => {
    setConnectionState("not_connected");
  };

  const handleRetry = () => {
    setConnectionState("not_connected");
  };

  // For demo purposes - trigger error state
  const simulateError = () => {
    setConnectionState("error");
  };

  return (
    <div className="min-h-screen bg-background flex flex-col items-center justify-center p-6">
      <div className="w-full max-w-md space-y-8">
        {/* Not Connected State */}
        {connectionState === "not_connected" && (
          <div className="space-y-8 animate-fade-in">
            {/* Header */}
            <div className="text-center space-y-3" style={{ animationDelay: "0.1s" }}>
              <h1 className="text-2xl font-bold text-foreground">
                Connect your music account
              </h1>
              <p className="text-muted-foreground text-sm">
                Connect your music account to control what plays during battles.
              </p>
            </div>

            {/* Provider List */}
            <div className="space-y-3" style={{ animationDelay: "0.2s" }}>
              {providers.map((provider) => (
                <button
                  key={provider.id}
                  onClick={provider.enabled ? handleConnect : undefined}
                  disabled={!provider.enabled}
                  className={`
                    w-full flex items-center justify-between p-4 rounded-xl
                    border transition-all duration-200
                    ${provider.enabled
                      ? "bg-surface border-border hover:border-primary/50 hover:bg-surface/80 cursor-pointer"
                      : "bg-surface/50 border-border/50 cursor-not-allowed opacity-50"
                    }
                  `}
                >
                  <div className="flex items-center gap-3">
                    <div className={`
                      w-10 h-10 rounded-lg flex items-center justify-center
                      ${provider.enabled ? "bg-primary/20 text-primary" : "bg-muted text-muted-foreground"}
                    `}>
                      {provider.icon}
                    </div>
                    <div className="text-left">
                      <p className={`font-medium ${provider.enabled ? "text-foreground" : "text-muted-foreground"}`}>
                        {provider.name}
                      </p>
                      {!provider.enabled && (
                        <p className="text-xs text-muted-foreground">Coming soon</p>
                      )}
                    </div>
                  </div>
                  {provider.enabled && (
                    <ChevronRight className="w-5 h-5 text-muted-foreground" />
                  )}
                </button>
              ))}
            </div>

            {/* Trust Note */}
            <p 
              className="text-center text-xs text-muted-foreground animate-fade-in"
              style={{ animationDelay: "0.3s" }}
            >
              We never store your password.
            </p>
          </div>
        )}

        {/* Connected State */}
        {connectionState === "connected" && (
          <div className="space-y-8 animate-fade-in">
            {/* Header */}
            <div className="text-center space-y-3">
              <div className="w-16 h-16 mx-auto rounded-full bg-primary/20 flex items-center justify-center mb-4">
                <Check className="w-8 h-8 text-primary" />
              </div>
              <h1 className="text-2xl font-bold text-foreground">
                Music account connected
              </h1>
            </div>

            {/* Connected Account Card */}
            <div 
              className="bg-surface border border-border rounded-xl p-4 animate-fade-in"
              style={{ animationDelay: "0.1s" }}
            >
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-lg bg-primary/20 flex items-center justify-center">
                    <Music className="w-5 h-5 text-primary" />
                  </div>
                  <div>
                    <p className="font-medium text-foreground">Spotify</p>
                    <p className="text-sm text-muted-foreground">dj_battlemaster</p>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-2 h-2 rounded-full bg-primary animate-pulse" />
                  <span className="text-sm text-primary font-medium">Connected</span>
                </div>
              </div>
            </div>

            {/* Actions */}
            <div 
              className="space-y-3 animate-fade-in"
              style={{ animationDelay: "0.2s" }}
            >
              <Button asChild className="w-full h-12 text-base font-semibold">
                <Link to="/stage">Go to Stage View</Link>
              </Button>
              <Button
                variant="ghost"
                onClick={handleDisconnect}
                className="w-full text-muted-foreground hover:text-foreground"
              >
                Disconnect
              </Button>
            </div>
          </div>
        )}

        {/* Error State */}
        {connectionState === "error" && (
          <div className="space-y-8 animate-fade-in">
            {/* Header */}
            <div className="text-center space-y-3">
              <div className="w-16 h-16 mx-auto rounded-full bg-destructive/20 flex items-center justify-center mb-4">
                <AlertCircle className="w-8 h-8 text-destructive" />
              </div>
              <h1 className="text-2xl font-bold text-foreground">
                Something went wrong
              </h1>
              <p className="text-muted-foreground text-sm">
                Please try again.
              </p>
            </div>

            {/* Retry Action */}
            <Button
              onClick={handleRetry}
              className="w-full h-12 text-base font-semibold"
            >
              Try again
            </Button>
          </div>
        )}

        {/* Dev helper - hidden in production */}
        {import.meta.env.DEV && connectionState === "not_connected" && (
          <button
            onClick={simulateError}
            className="text-xs text-muted-foreground/50 hover:text-muted-foreground transition-colors"
          >
            [Dev: Simulate error]
          </button>
        )}
      </div>
    </div>
  );
};

export default ConnectStreamingScreen;
