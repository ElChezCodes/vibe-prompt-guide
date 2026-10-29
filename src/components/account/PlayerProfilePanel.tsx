import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { getMyProfile, MyProfile, updateMyProfile } from "@/integrations/supabase/pi";
import { COUNTRIES, countryName } from "@/lib/countries";

const ERRORS: Record<string, string> = {
  invalid_nickname: "Nickname must be 2 to 20 characters",
  invalid_country: "Unknown country",
};

/**
 * Name and country shown in the leaderboards (step 15). The nickname starts
 * generated and can be changed; the country is optional and only declared
 * here (their own Spotify country is just a suggestion). Minimal markup; the
 * visual pass is done in Lovable.
 */
const PlayerProfilePanel = () => {
  const [profile, setProfile] = useState<MyProfile | null>(null);
  const [nickname, setNickname] = useState("");
  const [country, setCountry] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);

  const load = () =>
    getMyProfile().then((p) => {
      setProfile(p);
      setNickname(p && !p.is_generated ? p.nickname : "");
      setCountry(p?.country ?? "");
    });

  useEffect(() => {
    load();
  }, []);

  if (!profile) {
    return (
      <div className="flex justify-center py-4">
        <Loader2 className="w-5 h-5 animate-spin text-muted-foreground" />
      </div>
    );
  }

  const dirty = nickname.trim() !== (profile.is_generated ? "" : profile.nickname) || country !== (profile.country ?? "");

  const save = async () => {
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      await updateMyProfile(nickname, country || null);
      await load();
      setSaved(true);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      setError(ERRORS[message] ?? message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between gap-3">
        <p className="text-sm text-text-secondary">
          You appear as <span className="font-semibold text-foreground">{profile.nickname}</span>
        </p>
        <p className="text-sm font-semibold text-foreground whitespace-nowrap" title={`This month: ${profile.month_pi} PI`}>
          <span className="text-energy-yellow">PI</span> {profile.total_pi}
        </p>
      </div>

      <label className="block space-y-1">
        <span className="text-xs text-muted-foreground">Nickname</span>
        <Input
          value={nickname}
          maxLength={20}
          placeholder={profile.is_generated ? profile.nickname : "Leave empty for a generated one"}
          onChange={(e) => {
            setNickname(e.target.value);
            setSaved(false);
          }}
        />
      </label>

      <label className="block space-y-1">
        <span className="text-xs text-muted-foreground">Country (optional, for the country ranking)</span>
        <select
          value={country}
          onChange={(e) => {
            setCountry(e.target.value);
            setSaved(false);
          }}
          className="w-full h-10 rounded-md border border-input bg-background px-3 text-sm text-foreground"
        >
          <option value="">No country</option>
          {COUNTRIES.map((c) => (
            <option key={c.code} value={c.code}>
              {c.name}
            </option>
          ))}
        </select>
      </label>
      {!country && profile.suggested_country && (
        <button
          type="button"
          className="text-xs text-primary underline"
          onClick={() => {
            setCountry(profile.suggested_country);
            setSaved(false);
          }}
        >
          Use {countryName(profile.suggested_country)} (from your Spotify)
        </button>
      )}

      {!profile.is_account && (
        <p className="text-xs text-muted-foreground">
          You earn PI in your arenas; create an account to appear in the country and world rankings.
        </p>
      )}

      {error && <p className="text-xs text-destructive">{error}</p>}
      {saved && !dirty && <p className="text-xs text-primary">Saved</p>}
      <Button className="w-full" disabled={busy || !dirty} onClick={save}>
        {busy && <Loader2 className="w-4 h-4 animate-spin" />}
        Save
      </Button>
      <p className="text-[11px] text-muted-foreground">
        Shown to other players in rankings. See the <Link to="/privacy" className="underline">privacy policy</Link>.
      </p>
    </div>
  );
};

export default PlayerProfilePanel;
