#!/bin/sh
# Build releases/RetroHub.pak.zip: a standalone install of the RetroHub tool pak.
# Unzip it into the SD card's Tools/ folder (result: <SDCARD>/Tools/RetroHub.pak/).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/skeleton/SYSTEM/tg5040/paks/Tools"
OUT="$ROOT/releases/RetroHub.pak.zip"
mkdir -p "$ROOT/releases"
rm -f "$OUT"

if command -v zip >/dev/null 2>&1; then
    (cd "$SRC" && zip -qr "$OUT" RetroHub.pak -x '*/__pycache__/*' '*.pyc')
else
    # No zip binary: IO::Compress::Zip ships with perl.
    perl -MIO::Compress::Zip=:all -MFile::Find -e '
        my ($src, $out) = @ARGV;
        chdir $src or die $!;
        my $z;
        find({ no_chdir => 1, wanted => sub {
            my $f = $File::Find::name;
            return if $f =~ m{/__pycache__(/|$)} || $f =~ /\.pyc$/ || -d $f;
            my $mode = (stat $f)[2] & 07777;
            my $store = $f =~ /\.(tar\.gz|tar\.xz|zip|png|jpg)$/i || $f eq "RetroHub.pak/bin/yt-dlp";
            my %o = (Name => $f, Method => $store ? ZIP_CM_STORE : ZIP_CM_DEFLATE,
                     ExtAttr => ($mode | 0100000) << 16, Time => (stat $f)[9], Zip64 => 1);
            if (!$z) { $z = IO::Compress::Zip->new($out, %o) or die $ZipError }
            else     { $z->newStream(%o) }
            open my $in, "<:raw", $f or die "$f: $!";
            local $/ = \1048576;
            $z->print($_) while <$in>;
        }}, "RetroHub.pak");
        $z->close;
    ' "$SRC" "$OUT"
fi
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
