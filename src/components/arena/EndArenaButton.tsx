import { ReactNode } from "react";
import { endArena } from "@/integrations/supabase/arenas";
import { useRefreshCurrentArena } from "@/hooks/useCurrentArena";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";

interface EndArenaButtonProps {
  arenaId: string;
  onEnded: () => void;
  // The trigger element (styled by the screen that places it)
  children: ReactNode;
}

// Host only (end_arena enforces it): waiting|active -> finished. Leaving a
// screen never ends the arena; this is the only way.
const EndArenaButton = ({ arenaId, onEnded, children }: EndArenaButtonProps) => {
  const refreshCurrentArena = useRefreshCurrentArena();

  const handleEndArena = async () => {
    try {
      await endArena(arenaId);
      onEnded();
      refreshCurrentArena();
    } catch {
      // logged in endArena; arena state stays as the backend reports it
    }
  };

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>{children}</AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>End this arena?</AlertDialogTitle>
          <AlertDialogDescription>
            Battles stop and no more votes or proposals are accepted. This can't be undone.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction onClick={handleEndArena}>End Arena</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
};

export default EndArenaButton;
