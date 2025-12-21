import { useState } from "react";
import { Music } from "lucide-react";
import { Button } from "@/components/ui/button";
import ProposeSongModal from "./ProposeSongModal";

const ActionStrip = () => {
  const [isProposeSongOpen, setIsProposeSongOpen] = useState(false);

  return (
    <div className="w-full px-4 py-6">
      <div className="flex items-center justify-center">
        <Button
          variant="outline"
          onClick={() => setIsProposeSongOpen(true)}
          className="flex items-center gap-2 h-12 px-6 rounded-xl border-border/50 bg-secondary/50 hover:bg-secondary text-foreground"
        >
          <Music className="h-4 w-4" />
          <span className="font-medium">Propose Song</span>
        </Button>
      </div>

      <ProposeSongModal 
        open={isProposeSongOpen} 
        onOpenChange={setIsProposeSongOpen} 
      />
    </div>
  );
};

export default ActionStrip;
