import { PRIVACY_POLICY_VERSION } from "@/integrations/supabase/account";

// TODO(owner): the user will provide the contact email (step 7b, 2026-10-27)
const PRIVACY_CONTACT = "[contact email pending]";

// Privacy policy (Spotify Developer Terms V.12; needed for accounts, step 7b).
// Plain text on purpose: the visual pass is done in Lovable.
const PrivacyScreen = () => (
  <div className="w-full max-w-md mx-auto px-6 py-10 space-y-4 text-sm text-text-secondary">
    <h1 className="neon-heading text-2xl text-foreground">Privacy policy</h1>
    <p className="text-xs text-muted-foreground">Version {PRIVACY_POLICY_VERSION}</p>

    <p>
      Music Fighter is a private, non-commercial app for choosing music together at gatherings among friends. Contact:{" "}
      {PRIVACY_CONTACT}.
    </p>

    <h2 className="font-semibold text-foreground">What we store</h2>
    <ul className="list-disc pl-5 space-y-1">
      <li>A random user id for every visitor (no account needed to play).</li>
      <li>What you do in arenas: joining, votes, song proposals and when you were active.</li>
      <li>If you create an account: your email and when you accepted this policy.</li>
      <li>
        If you connect Spotify: encrypted access tokens, your Spotify display name, Premium status and chosen device.
        Hosts also get a private playlist created in their own Spotify account.
      </li>
    </ul>

    <h2 className="font-semibold text-foreground">What we don't do</h2>
    <ul className="list-disc pl-5 space-y-1">
      <li>
        Your Spotify playlists and Liked Songs are read only while you browse them to propose a song, shown only to you
        and never stored.
      </li>
      <li>We never build a taste profile from your Spotify data, never sell data and never show ads.</li>
    </ul>

    <h2 className="font-semibold text-foreground">Your Music Fighter profile</h2>
    <p>
      With an account, Music Fighter may build a music profile only from what you do inside Music Fighter (votes,
      proposals, likes), to suggest and weigh songs in arenas.
    </p>

    <h2 className="font-semibold text-foreground">How long</h2>
    <ul className="list-disc pl-5 space-y-1">
      <li>Individual votes are deleted 30 days after an arena ends (battle totals are kept).</li>
      <li>Your account and profile are kept until you delete them.</li>
      <li>Disconnecting Spotify deletes every Spotify datum we hold about you.</li>
    </ul>

    <h2 className="font-semibold text-foreground">Your choices</h2>
    <p>
      From Profile you can disconnect Spotify, sign out or delete your account. Deleting it removes your email, Spotify
      data and profile; your past votes and proposals stay in their arenas without anything that identifies you. To
      also remove Spotify's access, visit spotify.com/account/apps.
    </p>

    <h2 className="font-semibold text-foreground">Services we use</h2>
    <p>Supabase (database and sign-in), Spotify (music catalog and playback) and an email provider for sign-in codes.</p>
  </div>
);

export default PrivacyScreen;
