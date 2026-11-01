import { useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { Copy, Share2, UserPlus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { joinUrl } from "@/lib/arenaRoutes";

interface InviteButtonProps {
  arenaCode: string;
  arenaName?: string | null;
  className?: string;
}

// Step 20 (pilot 2026-10-31): any member can invite, not only the host. The
// same QR (/join/:code) and code the host's Lobby shows; the code is public
// to every member already, so nothing new is exposed.
const InviteButton = ({ arenaCode, arenaName, className }: InviteButtonProps) => {
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const url = joinUrl(arenaCode);
  const shownCode = arenaCode.replace(/(.{3})(.{3})/, "$1 $2");
  const canShare = typeof navigator !== "undefined" && typeof navigator.share === "function";

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  const handleShare = async () => {
    try {
      await navigator.share({ title: arenaName || "Music Fighter", text: `Join my Music Fighter arena: ${shownCode}`, url });
    } catch {
      // Cancelled by the user: nothing to do
    }
  };

  return (
    <>
      <button
        onClick={() => {
          setCopied(false);
          setOpen(true);
        }}
        className={className ?? "hud-chip inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-medium transition-colors"}
      >
        <UserPlus className="w-3.5 h-3.5" />
        Invite
      </button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="neon-panel max-w-sm mx-auto rounded-2xl">
          <DialogHeader>
            <DialogTitle className="neon-heading text-xl">Invite friends</DialogTitle>
            <DialogDescription>Scan the QR or enter the code in Music Fighter</DialogDescription>
          </DialogHeader>
          <div className="flex flex-col items-center gap-4">
            {/* Black on white with a quiet zone so phones read it */}
            <div className="bg-white rounded-xl p-4">
              <QRCodeSVG value={url} size={176} marginSize={1} />
            </div>
            <div className="text-center">
              <p className="neon-label mb-1">Arena Code</p>
              <p className="text-3xl font-bold text-foreground tracking-[0.3em] font-mono text-glow-a">{shownCode}</p>
            </div>
            <div className="w-full grid grid-cols-1 gap-2">
              {canShare && (
                <Button variant="neon" className="h-11" onClick={handleShare}>
                  <Share2 className="w-4 h-4" />
                  Share link
                </Button>
              )}
              <Button variant="neon" className="h-11" onClick={handleCopy}>
                <Copy className="w-4 h-4" />
                {copied ? "Link copied" : "Copy link"}
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
};

export default InviteButton;
