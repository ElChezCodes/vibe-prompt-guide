import { useState } from "react";
import { Music } from "lucide-react";
import { Button } from "@/components/ui/button";
import ProposeSongModal from "./ProposeSongModal";

interface ActionStripProps {
  arenaId: string;
}

const ActionStrip = ({ arenaId }: ActionStripProps) => {
  const [isProposeSongOpen, setIsProposeSongOpen] = useState(false);

  return (
    <div className="w-full px-4 py-6">
      <div className="flex items-center justify-center">
        <Button
          onClick={() => setIsProposeSongOpen(true)}
          className="flex items-center gap-2 h-12 px-6 rounded-xl bg-primary text-primary-foreground hover:bg-primary-hover"
        >
          <Music className="h-4 w-4" />
          <span className="font-semibold">Propose Song</span>
        </Button>
      </div>

      <ProposeSongModal
        open={isProposeSongOpen}
        onOpenChange={setIsProposeSongOpen}
        arenaId={arenaId}
      />
    </div>
  );
};

export default ActionStrip;
