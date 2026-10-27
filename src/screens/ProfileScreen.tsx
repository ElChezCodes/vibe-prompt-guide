import { useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { leaveArena } from "@/integrations/supabase/arenas";
import { useCurrentArena, useRefreshCurrentArena } from "@/hooks/useCurrentArena";
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

// Profile / achievements are placeholders (step 2b is navigation only). The
// functional part is "Leave arena": the explicit exit (Paso_2 §4.1), distinct
// from just browsing away from the Battle Room.
const ProfileScreen = () => {
  const navigate = useNavigate();
  const { data: current } = useCurrentArena();
  const refreshCurrentArena = useRefreshCurrentArena();

  const handleLeave = async () => {
    if (!current) return;
    try {
      await leaveArena(current.arena_id);
      await refreshCurrentArena();
      navigate("/");
    } catch {
      // logged in leaveArena
    }
  };

  return (
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center gap-6 px-6">
      <div className="text-center">
        <h1 className="text-2xl font-bold text-foreground">Profile</h1>
        <p className="text-sm text-muted-foreground">Avatar, account and achievements coming soon</p>
      </div>

      {current && (
        <div className="w-full max-w-xs flex flex-col items-center gap-2">
          <p className="text-sm text-muted-foreground">
            You're in <span className="text-foreground">{current.name}</span>
          </p>
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="outline" className="w-full">Leave arena</Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Leave this arena?</AlertDialogTitle>
                <AlertDialogDescription>
                  {current.is_host
                    ? "The arena keeps running; use End Arena to finish it. You can come back with the code."
                    : "You stop taking part until you enter again with the code."}
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={handleLeave}>Leave</AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
      )}
    </div>
  );
};

export default ProfileScreen;
