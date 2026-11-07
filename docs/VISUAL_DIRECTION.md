# Visual direction

**User decision, 2026-11-07:** pixel art is a **background layer**, not the interface.
It draws the **arena backgrounds** and the **characters (avatars)**, first in the
Battle Room and the Stage View, plus a sub-screen in Profile to choose an avatar.
Menus and cards are **not** pixel art. The Home logo stays as it is; Home's corner
notes are pixel sprites (`src/assets/pixel/`). Directions A, B and C (a pixel UI) were
discarded.

The user's references live outside the repo, in
`Desktop/Music_fighter/Console images`: arenas, avatars, target screens, and the visual
foundation and arena specs.

## Decisions (user, 2026-11-07)
- **Arenas:** regenerated in PixelLab from the user's venue list, chosen by the arena's
  mood, decoration only: `mood` never affects battle rules.
- **Layout:** one wide image, centre-cropped in portrait.
- **Tension:** a soft light layer over the background, never a different image.
- **Avatars:** original full-body chibi characters, about 8 at first, confirmed by a cost test.
  Each song shows its proposer's avatar under the cards, facing the other.
  System songs, lent Liked Songs and users without an avatar show a Music Fighter character.
- **Motion:** idle loop plus a win or lose pose, static with `prefers-reduced-motion`.
- **Content:** no bloody knife, no marked cleavage. Props are musical: headphones, plug
  cables and the like.
- **Choosing:** a sub-screen in Profile, also for anonymous users.

## Rules that win over those references
- Spotify artwork stays opaque, uncropped and uncovered. The old spec's semi-transparent
  covers don't apply.
- Nothing goes over the artwork or the tension bar. The background sits under the whole
  UI and never lowers contrast.
- The Stage View fits 720p without scrolling, the Battle Room works at 320 px, QRs stay
  scannable, and `prefers-reduced-motion` stops the background's motion.
- Characters are original. Never recreate a character, stage or sprite of an existing
  game; the games in the `Examples` folder are not inputs for generation.
- Backgrounds never explain state and never contain text, foreground people or a stage.
  The centre stays empty.
