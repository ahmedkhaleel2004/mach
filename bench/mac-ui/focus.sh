#!/bin/zsh
# Checks that the keyboard lands in the right place: presses real keys in a benchmark copy of the Mac app on the
# made-up mailbox and asks, after each, which control would get the next key.
#
#   bench/mac-ui/focus.sh            builds, runs, prints one line per step and exits 1 if any step is wrong
#
# Unlike the other benchmarks this one has to be in front (focus only behaves like the real thing in the key
# window, with real key events), so it takes the keyboard for about ten seconds and then hands it back.
set -eu
cd "$(dirname "$0")/../.."
channel=com.ahmedkhaleel.machbench.focus
app=$(bench/build.sh mac 2>/dev/null)
mkdir -p build/run
for tool in key press; do swiftc -O bench/mac-ui/$tool.swift -o build/run/$tool; done
[ -f build/data/synth/mail.sqlite ] || bench/data.sh >/dev/null
bench/data.sh fresh synth build/run/focus
front=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
: > build/run/focus.err
open -n "$app" --stderr "$PWD/build/run/focus.err" --env MACH_DATA_DIR="$PWD/build/run/focus" --env MACH_OFFLINE=1 --env MACH_DEBUG_CHANNEL=$channel
sleep 3
pid=$(pgrep -f "$app/Contents/MacOS/Mach")
trap 'kill $pid; osascript -e "tell application id \"$front\" to activate"' EXIT

# step: what it is, the keys (key codes for press, or ch:<command> for the debug channel), the control expected to hold the keyboard.
failed=0
step() {
  if [[ "$2" == ch:* ]]; then build/run/key $channel "${2#ch:}"; sleep 0.4; else build/run/press $pid ${=2}; fi
  : > build/run/focus.err
  build/run/key $channel responder; sleep 0.3
  got=$(sed -n 's/^responder: \([^ ]*\).*/\1/p' build/run/focus.err | tail -1)
  if [[ "$got" == $~3 ]]; then echo "ok    $1 ($got)"; else echo "WRONG $1: keyboard is in ${got:-nothing}, wanted $3"; failed=1; fi
}
field='_SystemTextFieldFieldEditor'; editor='PlatformTextView'; nothing='AppKitWindow'
step "command bar opens ready to type"            "40:cmd"      "$field"
step "escape gives the keyboard back"              "53"          "$nothing"
step "open a conversation"                         "36"          "$nothing"
step "R opens a reply ready to type"               "15"          "$editor"
step "escape closes the reply"                     "53"          "$nothing"
step "the conversation is clicked"                 "ch:focusweb" "WKWebView"
step "R still opens a reply ready to type"         "15"          "$editor"
step "escape closes the reply"                     "53"          "$nothing"
step "the conversation is clicked"                 "ch:focusweb" "WKWebView"
step "command bar still opens ready to type"       "40:cmd"      "$field"
step "escape gives the keyboard back"              "53"          "$nothing"
step "back to the list"                            "53"          "$nothing"
step "/ opens search ready to type"                "44"          "$field"
step "escape, then a new message is ready to type" "53 8"        "$field"
exit $failed
