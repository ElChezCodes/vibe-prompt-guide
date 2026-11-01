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
      {/* Step 20: the dialog scrolls as a whole (a fixed-height box left 2-3
          result rows on phones); the send button sticks at its bottom */}
      <DialogContent className="neon-panel max-w-md mx-auto max-h-[88dvh] overflow-y-auto flex flex-col gap-4 rounded-2xl pb-3">
        <DialogHeader className="flex-shrink-0">
          <DialogTitle className="neon-heading text-xl">
            Propose a Song
          </DialogTitle>
        </DialogHeader>

        {/* Stays open after proposing (more songs from the same search); closed by the user */}
        <ProposeSongPanel arenaId={arenaId} layout="page" stickyClassName="bottom-0" />
      </DialogContent>
    </Dialog>
  );
};

export default ProposeSongModal;
