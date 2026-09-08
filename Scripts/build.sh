#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${CONFIGURATION:-Release}
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration "$configuration" -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -jobs 6 ARCHS=arm64 build
python3 Scripts/sign-local.py "build.noindex/Build/Products/$configuration/LocalFlow.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/build.noindex/Build/Products/$configuration/LocalFlow.app" || true
printf '\nApplication: %s/build.noindex/Build/Products/%s/LocalFlow.app\n' "$PWD" "$configuration"
