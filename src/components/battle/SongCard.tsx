interface SongCardProps {
  position: 'left' | 'right';
  songTitle?: string;
  artistName?: string;
}

const SongCard = ({ 
  position, 
  songTitle = "Song Title", 
  artistName = "Artist Name" 
}: SongCardProps) => {
  return (
    <div className="flex-1 flex flex-col items-center p-3">
      {/* Album artwork placeholder */}
      <div className="w-full aspect-square bg-secondary rounded-lg flex items-center justify-center mb-3">
        <div className="w-12 h-12 rounded-full bg-muted" />
      </div>
      
      {/* Song info */}
      <div className="text-center w-full">
        <h3 className="text-sm font-semibold text-foreground truncate">
          {songTitle}
        </h3>
        <p className="text-xs text-muted-foreground truncate mt-1">
          {artistName}
        </p>
      </div>
    </div>
  );
};

export default SongCard;
