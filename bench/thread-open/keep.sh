#!/bin/sh
# Builds the Mac benchmark app from the working tree and keeps a copy as build/apps/<name>.app, for compare.sh.
set -eu
cd "$(dirname "$0")/../.."
app="$(DD=build/dd-mac bench/build.sh mac)"
mkdir -p build/apps
rm -rf "build/apps/$1.app"
cp -R "$app" "build/apps/$1.app"
echo "build/apps/$1.app"
