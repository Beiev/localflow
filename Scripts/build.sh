#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${CONFIGURATION:-Release}
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration "$configuration" -derivedDataPath build -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -jobs 6 build
printf '\nApplication: %s/build/Build/Products/%s/LocalFlow.app\n' "$PWD" "$configuration"
