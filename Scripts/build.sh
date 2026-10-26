#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${CONFIGURATION:-Release}
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration "$configuration" -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -jobs 6 ARCHS=arm64 build
# The archive's MCP server ships inside the bundle: one build, one signature, one path for the
# assistant's configuration to point at.
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlowMCP -configuration "$configuration" -derivedDataPath build.noindex -clonedSourcePackagesDirPath .build -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation -skipMacroValidation -jobs 6 ARCHS=arm64 build
cp "build.noindex/Build/Products/$configuration/LocalFlowMCP" "build.noindex/Build/Products/$configuration/LocalFlow.app/Contents/MacOS/localflow-mcp"
python3 Scripts/sign-local.py "build.noindex/Build/Products/$configuration/LocalFlow.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/build.noindex/Build/Products/$configuration/LocalFlow.app" || true
printf '\nApplication: %s/build.noindex/Build/Products/%s/LocalFlow.app\n' "$PWD" "$configuration"
printf 'Archive MCP server: %s/build.noindex/Build/Products/%s/LocalFlow.app/Contents/MacOS/localflow-mcp\n' "$PWD" "$configuration"
