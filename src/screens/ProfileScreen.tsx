import { useNavigate } from "react-router-dom";
import { Lock, LogOut, Swords, User } from "lucide-react";
import { Button } from "@/components/ui/button";
import { leaveArena } from "@/integrations/supabase/arenas";
import { useCurrentArena, useRefreshCurrentArena } from "@/hooks/useCurrentArena";
import SpotifyConnectionPanel from "@/components/streaming/SpotifyConnectionPanel";
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
// from just browsing away from the Battle Room. Anyone can connect Spotify
// here: it belongs to the user and is what lets them host their own arenas;
// in other people's arenas it is used only to propose songs (search with it,
// pick from their own playlists, step 7), never for taste profiling.
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
    <div className="min-h-[calc(100dvh-4rem)] w-full flex flex-col items-center justify-center gap-6 px-6 py-12">
      <h1 className="neon-heading text-3xl animate-fade-in-up">Profile</h1>

      {/* Avatar placeholder (no avatar system yet) */}
      <div className="flex flex-col items-center animate-fade-in-up" style={{ animationDelay: "50ms" }}>
        <div className="w-28 h-28 rounded-2xl neon-panel flex items-center justify-center">
          <User className="w-14 h-14 text-muted-foreground" />
        </div>
        <span className="-mt-3 px-3 py-1 rounded-md neon-outline text-xs font-semibold text-foreground">
          Avatar coming soon
        </span>
      </div>

      {/* Achievements placeholder */}
      <div
        className="w-full max-w-xs neon-panel rounded-2xl p-4 animate-fade-in-up"
        style={{ animationDelay: "100ms" }}
      >
        <p className="neon-label mb-3">Achievements</p>
        <div className="grid grid-cols-3 gap-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="aspect-square rounded-xl neon-row flex items-center justify-center">
              <Lock className="w-5 h-5 text-muted-foreground" />
            </div>
          ))}
        </div>
        <p className="mt-3 text-xs text-muted-foreground text-center">Coming soon</p>
      </div>

      {/* Spotify: to host your own arenas and propose from your own library */}
      <div
        className="w-full max-w-xs neon-panel rounded-2xl p-4 flex flex-col gap-3 animate-fade-in-up"
        style={{ animationDelay: "125ms" }}
      >
        <p className="neon-label">Your Spotify · to host arenas and propose from your playlists</p>
        <SpotifyConnectionPanel returnTo="/profile" />
      </div>

      {current && (
        <div
          className="w-full max-w-xs neon-panel rounded-2xl p-4 flex flex-col gap-3 animate-fade-in-up"
          style={{ animationDelay: "150ms" }}
        >
          <div className="flex items-center gap-3">
            <span className="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/15">
              <Swords className="w-5 h-5 text-primary icon-glow-primary" />
            </span>
            <p className="text-sm text-text-secondary min-w-0">
              You're in <span className="block text-base font-semibold text-foreground truncate">{current.name}</span>
            </p>
          </div>
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button
                variant="ghost"
                className="w-full border border-destructive/40 text-destructive/90 hover:bg-destructive/10 hover:text-destructive"
              >
                <LogOut className="w-4 h-4" />
                Leave arena
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent className="neon-panel rounded-2xl">
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
