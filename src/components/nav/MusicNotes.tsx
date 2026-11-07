// The Home screen's corner notes (user's drawings, 2026-11-06), as pixel art.
// The lean and the halo are drawn into the sprites: a CSS skew or a blur would
// break the pixel grid. Shown at whole multiples only (see .pixel-sprite).
import beamedNotes from "@/assets/pixel/notes-beamed.png";
import flaggedNote from "@/assets/pixel/note-flagged.png";

interface NoteProps {
  className?: string;
}

// Three beamed notes, 38x22 art pixels
export const BeamedNotes = ({ className = "" }: NoteProps) => (
  <img src={beamedNotes} alt="" aria-hidden draggable={false} className={`pixel-sprite ${className}`} />
);

// One note with a double flag (the "fusa"), 25x26 art pixels
export const FlaggedNote = ({ className = "" }: NoteProps) => (
  <img src={flaggedNote} alt="" aria-hidden draggable={false} className={`pixel-sprite ${className}`} />
);
