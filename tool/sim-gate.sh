#!/bin/zsh
# Nyx simulator release gate. Run on the Mac from the app tree: tool/sim-gate.sh <integration_test files...>
# Fixtures (gitignored, make once): mkdir .test_media; ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=60,noise=alls=40:allf=t" -f lavfi -i "sine=frequency=440" -t 80 -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p -c:a aac -shortest .test_media/big_moov_end.mp4
# plus .test_media/hevc_moov_end.mov (HEVC, -tag:v hvc1) and a few 4 s clips .test_media/poster_N.mp4 / poster_N.webm (VP9).
export PATH=$HOME/development/flutter/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8
cd "$(dirname "$0")/.." || exit 1
UDID=$(cat .sim-udid 2>/dev/null)
if [ -z "$UDID" ] || ! xcrun simctl list devices | grep -q "$UDID"; then
  UDID=$(xcrun simctl create nyx-gate "iPhone 17 Pro" | tail -1)
  echo "$UDID" > .sim-udid
fi
echo "sim $UDID"
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
cd ios && (pod install > ../pod-install.log 2>&1; echo "pod exit $?") && cd ..
for t in "$@"; do
  echo "=== $t"
  # Build+install first so the app container exists, then push the fixture.
  nice flutter test "$t" -d "$UDID" --no-pub > "gate-$(basename $t .dart).log" 2>&1 &
  PID=$!
  for i in $(seq 1 600); do
    C=$(xcrun simctl get_app_container "$UDID" com.angelonartey.nyx data 2>/dev/null)
    if [ -n "$C" ]; then mkdir -p "$C/Documents"; [ -f "$C/Documents/nyx_test_fixture.mp4" ] || cp .test_media/big_moov_end.mp4 "$C/Documents/nyx_test_fixture.mp4"; cp .test_media/poster_* "$C/Documents/" 2>/dev/null; [ -f .test_media/hevc_moov_end.mov ] && cp .test_media/hevc_moov_end.mov "$C/Documents/nyx_test_fixture_hevc.mov"; break; fi
    sleep 1
  done
  wait $PID; echo "exit $?"
  # Tests save screens to Documents/gate_shots/; collect them.
  C=$(xcrun simctl get_app_container "$UDID" com.angelonartey.nyx data 2>/dev/null)
  if [ -d "$C/Documents/gate_shots" ]; then mkdir -p gate-shots; mv "$C"/Documents/gate_shots/*.png gate-shots/ 2>/dev/null; fi
  grep -E "NYX_PERF|All tests passed|Some tests failed|\[E\]|Expected|Actual|Error" "gate-$(basename $t .dart).log" | head -40
done
echo GATE_DONE
