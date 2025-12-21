import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import ProposeSongModal from "./ProposeSongModal";

const ActionStrip = () => {
  const [isProposeSongOpen, setIsProposeSongOpen] = useState(false);

  return (
    <div className="w-full px-4 py-6">
      <div className="flex items-center justify-center gap-3">
        <Button
          variant="secondary"
          onClick={() => setIsProposeSongOpen(true)}
          className="flex items-center gap-2"
        >
          <Plus className="h-4 w-4" />
          <span>Propose Song</span>
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
