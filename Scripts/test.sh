#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlowCoreTests -configuration Debug -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -jobs 6 test
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlowInterfaceTests -configuration Debug -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -jobs 6 test
