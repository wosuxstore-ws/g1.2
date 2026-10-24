#!/usr/bin/env bash
# Runs inside the Android emulator job in GitHub Actions.
# Installs the freshly built APK, opens the game, waits, and reports whether it survived.
# If it crashed, the crash log is printed (and saved) so we can see the real reason.
#
# usage: bash tools/smoke_test.sh <path-to-apk> [output-dir]

APK="${1:-apk/app-release.apk}"
OUT="${2:-smoke-out}"
PKG="com.blockbloom.block_bloom"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p "$OUT"

echo "::group::Manifest inside the APK (what Android actually sees)"
AAPT2="$(find "${ANDROID_HOME:-/usr/local/lib/android/sdk}/build-tools" -name aapt2 2>/dev/null | sort -V | tail -n 1)"
if [ -n "$AAPT2" ]; then
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" > "$OUT/manifest.txt" 2>&1
  grep -E "APPLICATION_ID|EnableImpeller|INTERNET|package=|minSdk|targetSdk" -A1 "$OUT/manifest.txt" | head -n 40
else
  echo "(aapt2 not found - skipping manifest dump)"
fi
echo "::endgroup::"

adb logcat -b all -c
if ! adb install -r "$APK"; then
  echo "RESULT: the APK could not even be installed on the emulator."
  echo "RESULT: APK could not be installed on the emulator." >> "$SUMMARY"
  exit 2
fi

adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > "$OUT/launch.txt" 2>&1
sleep 25

adb logcat -d -b all > "$OUT/logcat-full.txt" 2>&1
adb logcat -d -b crash > "$OUT/crash-buffer.txt" 2>&1
adb shell dumpsys activity exit-info "$PKG" > "$OUT/exit-info.txt" 2>&1
adb exec-out screencap -p > "$OUT/screen.png" 2>/dev/null

PID="$(adb shell pidof "$PKG" | tr -d '\r')"
FILTER='FATAL EXCEPTION|Fatal signal|AndroidRuntime|backtrace:|has died|initialized incorrectly|Invalid application|ClassNotFound|NoClassDefFound|UnsatisfiedLink|NoSuchMethod|Unable to start|Process: '

{
  echo "===================== RESULT ====================="
  if [ -z "$PID" ]; then
    echo "THE APP IS NOT RUNNING after 25 s  =>  it crashed / closed itself."
    echo
    echo "----- crash buffer -----"
    head -n 120 "$OUT/crash-buffer.txt"
    echo
    echo "----- key lines from the full log -----"
    grep -n -E "$FILTER" "$OUT/logcat-full.txt" | head -n 60
    echo
    echo "----- how Android says the app ended -----"
    grep -E "reason|description|status|timestamp" "$OUT/exit-info.txt" | head -n 12
  else
    echo "The app is STILL RUNNING after 25 s (pid $PID)  =>  it starts fine on this emulator."
    echo "If it still closes on your phone, the cause is specific to your phone."
  fi
  echo "=================================================="
} | tee -a "$SUMMARY" | tee "$OUT/RESULT.txt"

[ -z "$PID" ] && exit 1
exit 0
