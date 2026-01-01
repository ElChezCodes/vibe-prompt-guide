import { useState } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { QrCode, Music } from "lucide-react";
import { Link } from "react-router-dom";
import { createArena } from "@/integrations/supabase/arenas";

const CreateArenaScreen = () => {
  const [arenaName, setArenaName] = useState("");
  const [isCreated, setIsCreated] = useState(false);

  // Mock arena code - in real app this would be generated
  const arenaCode = "847 291";

  const handleCreateArena = async () => {
    try {
      const result = await createArena();
      console.log('Arena created:', result);
      setIsCreated(true);
    } catch (error) {
      console.error('Failed to create arena:', error);
    }
  };

  return (
    <div className="min-h-dvh w-full flex flex-col items-center justify-center bg-background px-6 py-12">
      <div className="w-full max-w-md flex flex-col items-center gap-8">
        {/* Header */}
        <div className="text-center animate-fade-in-up">
          <h1 className="text-3xl md:text-4xl font-bold text-foreground mb-2">
            Create Arena
          </h1>
          <p className="text-muted-foreground">
            Set up your Music Fighter session
          </p>
        </div>

        {/* Arena Name Input */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "50ms" }}
        >
          <Input
            type="text"
            placeholder="Arena name (optional)"
            value={arenaName}
            onChange={(e) => setArenaName(e.target.value)}
            disabled={isCreated}
            className="w-full h-12 text-center text-lg bg-surface border-border/50 focus:border-primary/50"
          />
        </div>

        {/* Create Arena Button */}
        <div 
          className="w-full animate-fade-in-up" 
          style={{ animationDelay: "100ms" }}
        >
          <Button
            onClick={handleCreateArena}
            disabled={isCreated}
            className="w-full h-12 text-lg font-semibold"
          >
            {isCreated ? "Arena Created" : "Create Arena"}
          </Button>
        </div>

        {/* Created State - Arena Code, QR, and Next Steps */}
        {isCreated && (
          <div className="w-full flex flex-col items-center gap-8 animate-fade-in-up">
            {/* Arena Code Block */}
            <div className="w-full bg-surface rounded-xl border border-border/50 p-6 text-center">
              <p className="text-sm text-muted-foreground mb-3">Arena Code</p>
              <p className="text-4xl md:text-5xl font-bold text-foreground tracking-[0.3em] font-mono">
                {arenaCode}
              </p>
            </div>

            {/* QR Code Block */}
            <div className="bg-surface rounded-xl border border-border/50 p-6 text-center">
              <p className="text-sm text-muted-foreground mb-4">Scan to join</p>
              <div className="w-48 h-48 mx-auto bg-white rounded-lg flex items-center justify-center">
                {/* Mock QR placeholder */}
                <div className="w-40 h-40 relative">
                  <QrCode className="w-full h-full text-background" strokeWidth={0.5} />
                  {/* QR pattern overlay */}
                  <div className="absolute inset-4 grid grid-cols-7 grid-rows-7 gap-1">
                    {Array.from({ length: 49 }).map((_, i) => (
                      <div
                        key={i}
                        className={`rounded-sm ${
                          Math.random() > 0.5 ? "bg-background" : "bg-transparent"
                        }`}
                      />
                    ))}
                  </div>
                </div>
              </div>
            </div>

            {/* Next Steps Guidance */}
            <div className="w-full bg-surface/50 rounded-xl border border-border/30 p-5">
              <p className="text-sm font-medium text-foreground mb-3">Next steps</p>
              <ul className="space-y-2 text-sm text-muted-foreground">
                <li className="flex items-start gap-2">
                  <span className="text-primary">•</span>
                  Ask guests to join using the code or QR
                </li>
                <li className="flex items-start gap-2">
                  <span className="text-primary">•</span>
                  Display the Stage View on the venue screen
                </li>
                <li className="flex items-start gap-2">
                  <span className="text-primary">•</span>
                  Connect your music account to start battles
                </li>
              </ul>
            </div>

            {/* Secondary Action - Connect Music */}
            <Button
              variant="outline"
              asChild
              className="w-full h-12 border-border/50"
            >
              <Link to="/connect">
                <Music className="w-5 h-5 mr-2" />
                Connect music account
              </Link>
            </Button>
          </div>
        )}
      </div>
    </div>
  );
};

export default CreateArenaScreen;
