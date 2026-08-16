#!/bin/zsh
# Live view of rate following: what Music's decoder reports, what neiro decides,
# and what the DAC is actually running at.
#
#   scripts/watch-rates.sh [output-device-name-fragment]
#
# Pair it with the "neiro rate test" playlist (scripts/rate-test-playlist.applescript),
# where every track change crosses a rate boundary.

set -u
DEVICE="${1:-}"

# Current hardware rate of the output device, polled next to the log so the
# decision and its result line up in time.
poll_device_rate() {
	while true; do
		local line
		line=$(system_profiler SPAudioDataType 2>/dev/null |
			awk -v want="$DEVICE" '
				/^ *[A-Za-z].*:$/ { name = $0; sub(/^ */, "", name); sub(/:$/, "", name) }
				/Current SampleRate:/ {
					rate = $NF
					if (want == "" || index(tolower(name), tolower(want))) print name " @ " rate
				}' | head -3)
		[[ -n "$line" ]] && print -r -- "── device: ${line//$'\n'/ | }"
		sleep 5
	done
}

poll_device_rate &
POLLER=$!
trap 'kill $POLLER 2>/dev/null' EXIT INT TERM

/usr/bin/log stream --style compact --info \
	--predicate 'subsystem == "com.mitsuba.neiro" AND category == "rate"
		OR (process == "Music" AND eventMessage CONTAINS "Output format:")' |
	sed -E \
		-e 's/^[0-9-]+ ([0-9:]+)\.[0-9]+ [A-Za-z]+ +/\1 /' \
		-e 's/neiro\[[0-9:a-z]+\] \[com\.mitsuba\.neiro:rate\] /neiro  /' \
		-e 's/Music\[[0-9:a-z]+\] .*(AC[A-Za-z]+)\.cpp[^ ]* .*Output format: *([0-9]+ ch)?, *([0-9]+) Hz.*/Music  \1 → \3 Hz/'
