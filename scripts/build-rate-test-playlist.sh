#!/bin/zsh
# Builds a Music.app playlist whose neighbouring tracks always differ in sample
# rate, so every "next track" forces neiro to switch. Tracks inside one album
# share a rate, which makes an ordinary album useless for this.
#
#   scripts/build-rate-test-playlist.sh [tracks-to-probe]   # default 40
#
# Apple Music streams only reveal their rate once they start playing (the
# library metadata says "missing value"), so this probes candidates by playing
# each for a moment, then interleaves the rates it found. Probing hijacks
# playback for roughly 5 s per candidate — don't run it while listening.
#
# The result is written to docs/rate-map.tsv and the playlist "neiro rate test".

set -u
PROBE_COUNT="${1:-40}"
ROOT="${0:A:h:h}"
MAP="$ROOT/docs/rate-map.tsv"
PROBE_LIST="neiro probe"
TEST_LIST="neiro rate test"

mkdir -p "$ROOT/docs"

# One candidate per album: album mates share a rate, so probing several of them
# would burn a minute to learn one number.
print "▸ picking $PROBE_COUNT candidates (one per album)"
osascript - "$PROBE_COUNT" "$PROBE_LIST" <<'AS' || exit 1
on run argv
	set wanted to (item 1 of argv) as integer
	set listName to item 2 of argv
	with timeout of 900 seconds
		tell application "Music"
			if (exists playlist listName) then delete playlist listName
			set probe to (make new user playlist with properties {name:listName})
			-- One bulk fetch: asking 6500 track references for their album one at
			-- a time takes minutes of Apple events.
			set allAlbums to (album of every track of library playlist 1)
			set seen to {}
			set picked to 0
			repeat with k from 1 to (count of allAlbums)
				if picked ≥ wanted then exit repeat
				set a to item k of allAlbums
				if a is not "" and seen does not contain a then
					set end of seen to a
					duplicate (track k of library playlist 1) to probe
					set picked to picked + 1
				end if
			end repeat
		end tell
	end timeout
end run
AS

print "▸ probing (up to $((PROBE_COUNT * 10))s)"
: > "$MAP.tmp"
COUNT=$(osascript -e "tell application \"Music\" to count tracks of playlist \"$PROBE_LIST\"")
for i in {1..$COUNT}; do
	osascript -e "tell application \"Music\" to play track $i of playlist \"$PROBE_LIST\"" >/dev/null 2>&1
	# `sample rate` is filled in once the stream is actually running, and
	# `current track` keeps naming the previous one until it does — polling for
	# a real rate is what stops the map filling up with duplicates.
	line=""
	for _ in {1..10}; do
		sleep 1
		line=$(osascript -e 'tell application "Music" to get ((sample rate of current track) as text) & tab & (name of current track) & tab & (artist of current track)' 2>/dev/null)
		[[ -n "$line" && "$line" != missing* && "$line" != 0$'\t'* ]] && break
	done
	[[ -z "$line" || "$line" == missing* ]] && continue
	print -r -- "$line" >> "$MAP.tmp"
	printf '  %s\n' "$line"
done
osascript -e "tell application \"Music\" to pause" >/dev/null 2>&1
sort -u "$MAP.tmp" > "$MAP" && rm -f "$MAP.tmp"

print "▸ interleaving"
# Round-robin over the rate groups so consecutive entries never share a rate.
python3 - "$MAP" <<'PY' > "$MAP.order"
import sys, collections
groups = collections.OrderedDict()
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2: continue
    groups.setdefault(parts[0], []).append(parts[1])
order = sorted(groups, key=lambda r: -len(groups[r]))
while any(groups[r] for r in order):
    for r in order:
        if groups[r]:
            print(groups[r].pop(0))
PY

osascript - "$TEST_LIST" "$PROBE_LIST" "$MAP.order" <<'AS'
on run argv
	set testName to item 1 of argv
	set probeName to item 2 of argv
	set orderFile to item 3 of argv
	set titles to paragraphs of (read POSIX file (item 3 of argv) as «class utf8»)
	tell application "Music"
		if (exists playlist testName) then delete playlist testName
		set target to (make new user playlist with properties {name:testName})
		repeat with theTitle in titles
			if (theTitle as text) is not "" then
				set hits to (search library playlist 1 for (theTitle as text) only songs)
				if (count of hits) > 0 then duplicate (item 1 of hits) to target
			end if
		end repeat
		if (exists playlist probeName) then delete playlist probeName
		log ("playlist \"" & testName & "\": " & (count of tracks of target) & " tracks")
	end tell
end run
AS
rm -f "$MAP.order"
print "▸ rate map: docs/rate-map.tsv"
