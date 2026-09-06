#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlowCoreTests -configuration Debug -derivedDataPath build -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -jobs 6 test
