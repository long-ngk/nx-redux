#!/bin/sh
# Host test for apps/JM.pak/jm_scan.sh: builds fake jars with perl, runs the scan under dash.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v unzip >/dev/null || { echo "need unzip (sudo apt install unzip)"; exit 1; }
SH="$(command -v dash || command -v sh)"

GAMEDIR="$WORK/pak"
mkdir -p "$GAMEDIR/Jars/240x320" "$GAMEDIR/Jars/320x240" "$GAMEDIR/Jars/128x128" "$GAMEDIR/Jars/384x288"

# Game A: manifest icon + folded manifest line. Game B: no icon. Game C: path-traversal icon.
perl -MIO::Compress::Zip=zip,\$ZipError -e '
my ($dir) = @ARGV;
my $png = "\x89PNG\r\n\x1a\n" . ("x" x 32);
sub mk {
    my ($file, $manifest, %extra) = @_;
    my $z = IO::Compress::Zip->new($file, Name => "META-INF/MANIFEST.MF", Method => 8) or die $ZipError;
    $z->print($manifest);
    for my $n (keys %extra) { $z->newStream(Name => $n, Method => 8); $z->print($extra{$n}); }
    $z->close;
}
mk("$dir/Jars/240x320/GameA.jar",
   "MIDlet-Name: Game A\r\nMIDlet-Vendor: Vendor\r\n A\r\nMIDlet-Version: 1.2\r\nMIDlet-Icon: /icon.png\r\n",
   "icon.png" => $png);
mk("$dir/Jars/320x240/GameB.jar", "MIDlet-Name: Game B\r\n");
mk("$dir/Jars/320x240/GameC.jar", "MIDlet-Name: Game C\r\nMIDlet-Icon: ../evil.png\r\n", "evil.png" => $png);
' "$GAMEDIR"

fail=0
check() { # desc cmd...
    desc="$1"; shift
    if "$@"; then echo "ok   $desc"; else echo "FAIL $desc"; fail=1; fi
}

rm -f /tmp/jar_128 /tmp/jar_240 /tmp/jar_320 /tmp/jar_384
GAMEDIR="$GAMEDIR" "$SH" -c '. "$1/apps/JM.pak/jm_scan.sh"; run_scan; extract_missing_thumbnails; extract_missing_info' _ "$ROOT" >"$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; exit 1; }

check "scan lists GameA in 240" grep -q GameA.jar /tmp/jar_240
check "scan lists GameB in 320" grep -q GameB.jar /tmp/jar_320
check "GameA thumbnail extracted" test -s "$GAMEDIR/Jars/240x320/GameA.png"
check "GameB has no thumbnail" test ! -e "$GAMEDIR/Jars/320x240/GameB.png"
check "traversal icon rejected" test ! -e "$GAMEDIR/Jars/320x240/GameC.png"
check "GameA info name" test "$(sed -n 1p "$GAMEDIR/Jars/240x320/GameA.info")" = "Game A"
check "GameA info version" test "$(sed -n 2p "$GAMEDIR/Jars/240x320/GameA.info")" = "1.2"
check "GameA info folded vendor" test "$(sed -n 3p "$GAMEDIR/Jars/240x320/GameA.info")" = "VendorA"
check "GameB info created" test -e "$GAMEDIR/Jars/320x240/GameB.info"

exit "$fail"
