#!/bin/bash
# Stage 1: install tapflow on a stock GitHub runner, then measure flows against the probe app.
# Every failure is a result to report, so nothing here aborts on error.
R="$PWD/results"; mkdir -p "$R/runs"
note() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$R/summary.txt"; }
export TAPFLOW_HOME="$HOME/.tapflow"

note "host: $(sw_vers -productVersion) $(uname -m) $(sysctl -n hw.ncpu)cpu $(($(sysctl -n hw.memsize)/1073741824))GB xcode=$(xcodebuild -version | head -1)"
sysctl -n kern.hv_vmm_present | xargs echo "virtual machine:" >> "$R/summary.txt"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p build/Probe.app
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
  -sdk "$SDK" probe/App.swift -o build/Probe.app/Probe > "$R/build.log" 2>&1
note "probe compile exit=$?"
cp probe/Info.plist build/Probe.app/Info.plist
codesign -s - --force build/Probe.app >> "$R/build.log" 2>&1
(cd build && zip -qry Probe.app.zip Probe.app)

t0=$SECONDS
npm install -g tapflow@0.32.0 > "$R/npm-install.log" 2>&1
note "npm install exit=$? in $((SECONDS-t0))s version=$(tapflow --version 2>&1 | head -1)"
tapflow doctor ios > "$R/doctor.txt" 2>&1; note "doctor exit=$?"
tapflow init > "$R/init.txt" 2>&1; note "init exit=$?"

t0=$SECONDS
nohup tapflow start > "$R/tapflow-start.log" 2>&1 &
for _ in $(seq 1 90); do curl -sf localhost:4000/api/v1/auth/status > "$R/auth-status.json" && break; sleep 2; done
note "relay up after $((SECONDS-t0))s: $(cat "$R/auth-status.json")"

code=$(curl -s -o "$R/auth-init.json" -w '%{http_code}' -X POST localhost:4000/api/v1/auth/init \
  -H 'Content-Type: application/json' -d "{\"email\":\"eval@example.com\",\"password\":\"$ADMIN_PW\"}")
note "admin init http=$code"
code=$(curl -s -c cookies -o /dev/null -w '%{http_code}' -X POST localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' -d "{\"email\":\"eval@example.com\",\"password\":\"$ADMIN_PW\"}")
note "login http=$code"
curl -s -b cookies -F "file=@build/Probe.app.zip" -F "label=eval" localhost:4000/api/v1/builds > "$R/upload.json"
BUILD_ID=$(jq -r .id "$R/upload.json")
note "upload build id=$BUILD_ID: $(jq -c '{bundle_id,platform,error}' "$R/upload.json")"
echo "BUILD_ID=$BUILD_ID" > results/ids.env

DEVICE=$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key|test("iOS")) | .value[] | select(.name|test("^iPhone 1[67]$"))][-1].name')
echo "DEVICE='$DEVICE'" >> results/ids.env
note "device=$DEVICE"
tapflow devices > "$R/devices.txt" 2>&1; tapflow status > "$R/status.txt" 2>&1

run_flow() { # label flowfile extra-args...
  local label=$1 flow=$2; shift 2
  local start=$SECONDS
  tapflow flow run "$flow" --device "$DEVICE" --build "$BUILD_ID" \
    --junit "$R/runs/$label.xml" --artifacts "$R/runs/$label-artifacts" "$@" > "$R/runs/$label.log" 2>&1
  local rc=$?
  note "$label exit=$rc in $((SECONDS-start))s"
  xcrun simctl io booted screenshot "$R/runs/$label.png" > /dev/null 2>&1
  local box
  box=$(xcrun simctl get_app_container booted dev.probe.tapflow data 2>/dev/null)
  [ -n "$box" ] && cp "$box/Documents/events.log" "$R/runs/$label-events.log" 2>/dev/null
}

# Cold first run measures boot; the repeats measure flakiness.
for i in 1 2 3 4 5 6 7 8; do run_flow "core-$i" flows/core.yaml; done
run_flow toggle flows/toggle.yaml
run_flow must-fail flows/must-fail.yaml # correct result is exit 1: proves failures are not hidden

curl -s -b cookies localhost:4000/api/v1/runs > "$R/runs.json"
tapflow status > "$R/status-after.txt" 2>&1
tapflow logs > "$R/relay-logs.txt" 2>&1
note "stage1 done"
