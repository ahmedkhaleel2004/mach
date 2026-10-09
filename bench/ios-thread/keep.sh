#!/bin/sh
# Builds the iPhone benchmark app from the working tree and keeps a copy as build/apps/<name>.app, for ab.sh.
set -eu
cd "$(dirname "$0")/../.."
app="$(DD="${DD:-build/dd-ios-thread}" bench/build.sh ios)"
mkdir -p build/apps
rm -rf "build/apps/$1.app"
cp -R "$app" "build/apps/$1.app"
echo "$PWD/build/apps/$1.app"
