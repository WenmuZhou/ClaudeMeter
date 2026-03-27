#!/bin/bash

# Build ClaudeMeter with Xcode

set -e

echo "Building ClaudeMeter..."

xcodebuild -project ClaudeMeter.xcodeproj \
  -scheme ClaudeMeter \
  -configuration Release \
  -derivedDataPath ./build \
  clean build

# Copy app to project root
cp -R ./build/Build/Products/Release/ClaudeMeter.app ./

echo ""
echo "Build complete: ClaudeMeter.app ($(du -sh ClaudeMeter.app | cut -f1))"
