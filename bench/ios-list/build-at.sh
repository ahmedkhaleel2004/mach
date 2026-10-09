#!/bin/sh
# Builds the benchmark app as it was at some commit, but with today's benchmark code, so "before" and "after" are
# measured by exactly the same scenarios. Prints the path of the app, kept under build/apps.
#
#   bench/ios-list/build-at.sh <commit> <name>       e.g.  bench/ios-list/build-at.sh 1a2b3c4 before
#   bench/ios-list/build-at.sh WORK after            the working tree as it is now
set -eu
cd "$(dirname "$0")/../.."
root="$PWD"
commit="$1"; name="$2"
mkdir -p build/apps
if [ "$commit" = WORK ]; then
  app=$(MACH_DATA_DIR=/nonexistent DD=build/dd-ios-list bench/build.sh ios | tail -1)
else
  src="$root/build/src-$name"
  rm -rf "$src/App" "$src/Core/Sources" "$src/bench"; mkdir -p "$src"
  git archive "$commit" App Core bench | tar -x -C "$src"
  # Today's scenarios over that day's app. The counters in the views themselves belong to the commit.
  cp App/iOS/ListBench.swift App/iOS/ListLab.swift App/iOS/ListEqLab.swift "$src/App/iOS/"
  [ -f "$src/Core/.build/workspace-state.json" ] || true
  app=$(cd "$src" && MACH_DATA_DIR=/nonexistent DD=build/dd bench/build.sh ios | tail -1)
fi
rm -rf "build/apps/$name.app"
cp -R "$app" "build/apps/$name.app"
echo "$root/build/apps/$name.app"
