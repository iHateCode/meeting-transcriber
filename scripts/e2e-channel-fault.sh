#!/usr/bin/env bash
# E2E test for the capture-fault path (issue #614): the app must report a
# channel that has stopped delivering, and stay quiet about one that is merely
# quiet.
#
# This is the lane that pins the distinction the old implementation could not
# make. It used to warn whenever one channel was quieter than the other for the
# debounce window, which is what a muted or listening microphone looks like, so
# the warning fired on a large share of ordinary meetings and was dismissed on
# reflex.
#
# One recording, two phases, in this order because the fault latches once per
# recording:
#
#   Phase 1 (the regression): low-level noise plays into BlackHole 2ch, so the
#     microphone track carries real samples below the -60 dBFS silence
#     threshold while the simulator's fixture keeps the app track above the
#     -50 dBFS speech threshold. The asymmetric-silence episode must latch
#     (micSilent == true, proving the pre-fix trigger condition was really
#     met), and nothing may be reported.
#
#   Phase 2 (the control): the noise stops, the microphone track becomes exact
#     zeroes, everything else is unchanged. Now the fault must be reported,
#     exactly once, with the digital-silence wording.
#
# The two phases are each other's control, which is the point of running them
# in one recording. An app that reports nothing at all sails through phase 1
# and fails phase 2; one that reports everything quiet fails phase 1. Neither
# assertion is worth much alone.
#
# Why the noise needs its own player rather than a routing change: BlackHole
# loops back whatever any client plays into it, regardless of the system
# default, so scripts/play-quiet-noise.swift addresses it directly and the
# default output is never touched. Rerouting it (as --mic-only does) would put
# the simulator's fixture into the microphone track at full level and destroy
# the asymmetry. The app track is unaffected either way: it comes from the
# process tap, which reads process output and touches no device.
#
# What this does NOT cover:
#   - noBuffers on a live channel. Producing it means unplugging hardware or
#     killing coreaudiod, neither of which belongs on a shared runner. The
#     two faults differ only in value logic, which unit tests pin.
#   - That the user SEES the notification. `posted` proves the app handed it to
#     UNUserNotificationCenter, nothing more.
#   - The urgency split. The ring-buffer entry carries no urgency field, so
#     that stays at unit level on the pure `captureAlert`.
#   - Whether real hardware mutes deliver zeroes rather than dither. That is
#     the field question this lane cannot answer for any device but BlackHole.
#
# Runs on:
#   - A macOS host with an Aqua GUI session and BlackHole 2ch as the default
#     input (the self-hosted Mac mini's standing configuration).
#
# Usage: bash scripts/e2e-channel-fault.sh [--no-build]

set -euo pipefail

NO_BUILD=false

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=true ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"
DEV_BUNDLE_BUILD="$ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app"
# Stable deploy path so the runner's manual TCC grants survive rebuilds; see
# scripts/e2e-silent-recording.sh for the full reasoning.
DEV_BUNDLE_DEPLOY="$HOME/Applications/MeetingTranscriber-Dev.app"
BIN="$DEV_BUNDLE_DEPLOY/Contents/MacOS/MeetingTranscriber"
MTCLI="$ROOT/tools/mt-cli/.build/debug/mt-cli"
SIM="$ROOT/tools/meeting-simulator/.build/release/meeting-simulator"
NOISE="$ROOT/scripts/play-quiet-noise.swift"
# shellcheck source=lib/bundle-ids.sh
source "$ROOT/scripts/lib/bundle-ids.sh"
BUNDLE_ID="$DEV_BUNDLE_ID"
REC_DIR="$HOME/Library/Application Support/MeetingTranscriber/recordings"
RUN_START_MARKER="$(mktemp "${TMPDIR:-/tmp}/e2e-channel-fault-start.XXXXXX")"

# The loopback device the microphone track reads from. Named, not a UID:
# this is what the runner setup documents and what a person sees in System
# Settings.
NOISE_DEVICE="BlackHole 2ch"
# Comfortably under the -60 dBFS silence threshold and comfortably above
# digital zero, which is the whole state under test.
NOISE_DBFS=-70
# The window both monitors use, pushed to the 30 s floor the production clamp
# allows so the lane costs two minutes rather than six.
WINDOW_SECONDS=30

SAVED_AUTOWATCH=""
SAVED_THRESHOLD=""
SAVED_INDICATOR=""

cleanup() {
    if [ -n "${NOISE_PID:-}" ] && kill -0 "$NOISE_PID" 2>/dev/null; then
        kill -TERM "$NOISE_PID" 2>/dev/null || true
    fi
    if [ -n "${SIM_PID:-}" ] && kill -0 "$SIM_PID" 2>/dev/null; then
        kill -TERM "$SIM_PID" 2>/dev/null || true
    fi
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -9 "$APP_PID" 2>/dev/null || true
    fi
    sweep_run_artifacts "$REC_DIR" "$RUN_START_MARKER"
    rm -f "${RUN_START_MARKER:-}" 2>/dev/null || true
    restore_bool_default  "$BUNDLE_ID" autoWatch                       "$SAVED_AUTOWATCH"
    restore_float_default "$BUNDLE_ID" asymmetricSilenceWarningSeconds "$SAVED_THRESHOLD"
    restore_bool_default  "$BUNDLE_ID" perChannelIndicatorEnabled      "$SAVED_INDICATOR"
    bootout_stale_launchctl
}
trap cleanup EXIT

# --- 1. Build + deploy ------------------------------------------------------

if [ "$NO_BUILD" = false ]; then
    echo "▸ Building dev .app…"
    "$ROOT/scripts/run_app.sh" --build-only >/dev/null
    # meeting-simulator and mt-cli live under separate `.build/` dirs and
    # share no targets, so they can compile in parallel. Cuts ~5–15 s off
    # the cold-cache path. meeting-simulator is built in release to match
    # scripts/e2e-app.sh's `SIMULATOR_BIN` path — re-using its
    # pre-existing build under `--no-build` instead of producing a second
    # debug copy.
    echo "▸ Building meeting-simulator + mt-cli (parallel)…"
    (cd "$ROOT/tools/meeting-simulator" && swift build -c release >/dev/null) &
    SIM_BUILD_PID=$!
    (cd "$ROOT/tools/mt-cli" && swift build >/dev/null) &
    CLI_BUILD_PID=$!
    # `wait $PID1 $PID2` only returns the exit code of the LAST PID — an
    # earlier failure would be silently dropped and surface ~60 lines down
    # as the confusing "required binary missing" guard. Wait individually so
    # whichever build failed is the failure that actually halts the script.
    wait "$SIM_BUILD_PID" || die "meeting-simulator build failed"
    wait "$CLI_BUILD_PID" || die "mt-cli build failed"

    # Deploy to the stable path and re-sign with the runner's dev cert so
    # the manual TCC grant (keyed on the cert SHA) keeps Microphone + Screen
    # Recording granted. Same pattern as scripts/e2e-app.sh — without this the
    # recorder runs but emits zero-byte WAVs because TCC denies the capture stack.
    echo "▸ Deploying to ${DEV_BUNDLE_DEPLOY} ..."
    mkdir -p "$(dirname "$DEV_BUNDLE_DEPLOY")"
    if [ -d "$DEV_BUNDLE_DEPLOY" ]; then
        rsync -a --delete "$DEV_BUNDLE_BUILD/" "$DEV_BUNDLE_DEPLOY/"
    else
        cp -R "$DEV_BUNDLE_BUILD" "$DEV_BUNDLE_DEPLOY"
    fi
    if [ -n "${DEVELOPER_ID:-}" ]; then
        echo "▸ Re-signing with Developer ID '$DEVELOPER_ID'…"
        resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$DEVELOPER_ID" "${E2E_SIGNING_KEYCHAIN:-}" \
            || die "Developer ID re-sign failed"
    else
        # Local-dev path: self-signed cert from setup-self-hosted-runner.sh,
        # resolved from the keychain by dev_signing_identity.
        if [ -f "$DEV_KEYCHAIN" ]; then
            DEV_CERT_HASH="$(dev_signing_identity)"
            if [ -n "$DEV_CERT_HASH" ]; then
                echo "▸ Re-signing with self-signed dev cert (SHA1=${DEV_CERT_HASH})..."
                # codesign honours `--keychain` for the signing identity but
                # still consults the user-domain search list for trust-chain
                # resolution. Prepending the dev keychain matches scripts/e2e-app.sh.
                "$ROOT/scripts/keychain-prepend.sh" "$DEV_KEYCHAIN" 2>/dev/null || true
                resign_deployed_bundle "$DEV_BUNDLE_DEPLOY" "$DEV_CERT_HASH" "$DEV_KEYCHAIN" \
                    || die "dev-cert re-sign failed"
            else
                echo "  Run scripts/setup-self-hosted-runner.sh to (re-)create it" >&2
                die "dev keychain present but no '$DEV_CERT_NAME' identity inside"
            fi
        else
            echo "▸ WARNING: no DEVELOPER_ID and no $DEV_KEYCHAIN — TCC may deny capture" >&2
            echo "  (run scripts/setup-self-hosted-runner.sh to fix)"
        fi
    fi
fi

for path in "$BIN" "$MTCLI" "$SIM"; do
    [ -x "$path" ] || die "required binary missing: $path — run without --no-build first"
done

# --- 2. Snapshot + override defaults so the test is deterministic -----------

SAVED_AUTOWATCH="$(snapshot_default "$BUNDLE_ID" autoWatch)"
SAVED_THRESHOLD="$(snapshot_default "$BUNDLE_ID" asymmetricSilenceWarningSeconds)"
SAVED_INDICATOR="$(snapshot_default "$BUNDLE_ID" perChannelIndicatorEnabled)"

/usr/bin/defaults write "$BUNDLE_ID" autoWatch -bool true
/usr/bin/defaults write "$BUNDLE_ID" asymmetricSilenceWarningSeconds -float "$WINDOW_SECONDS"
/usr/bin/defaults write "$BUNDLE_ID" perChannelIndicatorEnabled -bool true

# --- 3. Kill any running instance -------------------------------------------

quit_running_app "$BUNDLE_ID"

# --- 4. Launch app with RPC enabled -----------------------------------------

env MEETINGTRANSCRIBER_DEBUG_RPC=1 "$BIN" &
APP_PID=$!

echo "▸ Waiting for RPC on 127.0.0.1:9876…"
wait_for_rpc "$MTCLI" 30 || die "RPC server did not start within 30 s"
echo "  RPC up"

# --- 5. Start the quiet producer BEFORE the meeting -------------------------

# Before, so the microphone track is already alive when the recording opens.
# Starting it afterwards would leave an opening stretch of true zeroes that
# could reach the window on its own and report before phase 1 asserts.
echo "▸ Playing ${NOISE_DBFS} dBFS noise into \"$NOISE_DEVICE\"…"
"$NOISE" --device "$NOISE_DEVICE" --dbfs "$NOISE_DBFS" &
NOISE_PID=$!
sleep 2
kill -0 "$NOISE_PID" 2>/dev/null \
    || die "noise player exited immediately — is \"$NOISE_DEVICE\" installed? (brew install blackhole-2ch)"

# --- 6. Trigger an audible meeting ------------------------------------------

# Audible and looping: the app track has to carry speech for the whole run,
# because digital silence on the microphone is only reported while the other
# channel proves the recording is capturing something. Without --loop the
# fixture would end mid-lane and take the meeting with it.
echo "▸ Launching meeting-simulator (audible, looping, 150 s)…"
"$SIM" --loop --duration=150 &
SIM_PID=$!

echo "▸ Waiting for the app to detect and start recording (max 40 s)…"
_recording_started() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    [ "$(echo "$state" | jq -r '.watchState // ""')" = "recording" ]
}
poll_until 40 1 _recording_started || die "app never entered the recording state"
echo "  recording"

# --- 7. Phase 1: a live but quiet microphone must not be reported -----------

# Event-based rather than a fixed sleep: detection latency varies by several
# seconds, and asserting at a wall-clock offset would race it.
echo "▸ Phase 1: waiting for the silence episode to latch…"
_mic_episode_latched() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    [ "$(echo "$state" | jq -r '.channelHealth.micSilent // false')" = "true" ]
}
poll_until $((WINDOW_SECONDS + 30)) 2 _mic_episode_latched \
    || die "the asymmetric-silence episode never latched — the pre-fix trigger condition did not occur, so this run proves nothing"

STATE="$("$MTCLI" state)"
MIC_FAULT="$(echo "$STATE" | jq -r '.channelHealth.micFault // "null"')"
MIC_ENERGY_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastEnergy // -1')"
SILENT_NOTIFICATIONS="$(echo "$STATE" | jq '[.notifications[]? | select(.title == "Capture Channel Silent")] | length')"

[ "$MIC_FAULT" = "null" ] \
    || die "phase 1: micFault=$MIC_FAULT — a channel delivering real samples was reported as broken"
awk "BEGIN { exit !($MIC_ENERGY_AGE >= 0 && $MIC_ENERGY_AGE < 5) }" \
    || die "phase 1: micSecondsSinceLastEnergy=$MIC_ENERGY_AGE — the noise is not reaching the capture layer, so the phase asserts nothing"
[ "$SILENT_NOTIFICATIONS" = "0" ] \
    || die "phase 1: $SILENT_NOTIFICATIONS 'Capture Channel Silent' notification(s) for a live microphone — this is the issue #614 regression"

echo "  micSilent=true (tint latched), micFault=null, energy age=${MIC_ENERGY_AGE}s, no notification"

# --- 8. Phase 2: the same channel, now delivering zeroes --------------------

echo "▸ Phase 2: stopping the noise, the microphone track goes to digital silence…"
kill -TERM "$NOISE_PID" 2>/dev/null || true
wait "$NOISE_PID" 2>/dev/null || true
NOISE_PID=""

_mic_fault_reported() {
    assert_app_alive
    local state; state="$("$MTCLI" state 2>/dev/null || echo '{}')"
    [ "$(echo "$state" | jq -r '.channelHealth.micFault // "null"')" = "digitalSilence" ]
}
if ! poll_until $((WINDOW_SECONDS + 30)) 2 _mic_fault_reported; then
    echo "Final state:" >&2
    "$MTCLI" state 2>/dev/null | jq '.channelHealth, .watchState' >&2 || true
    die "phase 2: micFault never became digitalSilence — a channel delivering nothing but zeroes went unreported"
fi

STATE="$("$MTCLI" state)"
APP_FAULT="$(echo "$STATE" | jq -r '.channelHealth.appFault // "null"')"
MIC_ENERGY_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastEnergy // -1')"
MIC_BUFFER_AGE="$(echo "$STATE" | jq -r '.channelHealth.micSecondsSinceLastBuffer // -1')"
SILENT_NOTIFICATIONS="$(echo "$STATE" | jq '[.notifications[]? | select(.title == "Capture Channel Silent")] | length')"
SILENT_BODY="$(echo "$STATE" | jq -r '[.notifications[]? | select(.title == "Capture Channel Silent")][0].body // ""')"

[ "$SILENT_NOTIFICATIONS" = "1" ] \
    || die "phase 2: expected exactly one 'Capture Channel Silent', got $SILENT_NOTIFICATIONS"
case "$SILENT_BODY" in
    *"delivering silence"*) ;;
    *) die "phase 2: the notification does not carry the digital-silence wording: $SILENT_BODY" ;;
esac
[ "$APP_FAULT" = "null" ] \
    || die "phase 2: appFault=$APP_FAULT — the app track was carrying the fixture and must stay healthy"
awk "BEGIN { exit !($MIC_ENERGY_AGE >= $WINDOW_SECONDS) }" \
    || die "phase 2: micSecondsSinceLastEnergy=$MIC_ENERGY_AGE, below the window — the verdict does not match its own evidence"
# Buffers must still be arriving: that is what separates a muted device from a
# dead one, and reporting the wrong one sends the user after the wrong fix.
awk "BEGIN { exit !($MIC_BUFFER_AGE >= 0 && $MIC_BUFFER_AGE < 5) }" \
    || die "phase 2: micSecondsSinceLastBuffer=$MIC_BUFFER_AGE — the device stopped delivering entirely, which is noBuffers, not digitalSilence"

echo "  micFault=digitalSilence, buffer age=${MIC_BUFFER_AGE}s, energy age=${MIC_ENERGY_AGE}s, one notification"

echo
echo "OK — the capture-fault chain is verified end to end:"
echo "  live but quiet microphone  → tint, no notification"
echo "  same channel, zeroes only  → digitalSilence, one notification"
echo "  app track throughout       → healthy"
