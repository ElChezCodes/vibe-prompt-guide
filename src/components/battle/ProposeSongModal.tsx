import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import ProposeSongPanel from "./ProposeSongPanel";

interface ProposeSongModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  arenaId: string;
}

// In-battle entry point; the Proponer screen renders the same panel
const ProposeSongModal = ({ open, onOpenChange, arenaId }: ProposeSongModalProps) => {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="neon-panel max-w-md mx-auto h-[80vh] flex flex-col gap-4 rounded-2xl">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle className="neon-heading text-xl">
            Propose a Song
          </DialogTitle>
        </DialogHeader>

        <div className="flex-1 min-h-0">
          <ProposeSongPanel arenaId={arenaId} onProposed={() => onOpenChange(false)} />
        </div>
      </DialogContent>
    </Dialog>
  );
};

export default ProposeSongModal;
