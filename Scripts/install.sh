#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="build/Build/Products/${CONFIGURATION:-Release}/LocalFlow.app"
[[ -d "$app" ]] || { echo 'Run Scripts/build.sh first'; exit 1; }
mkdir -p "$HOME/Applications"
staging=$(mktemp -d "$HOME/Applications/.localflow-install.XXXXXX")
ditto "$app" "$staging/LocalFlow.app"
codesign --verify --deep --strict "$staging/LocalFlow.app"
if [[ -d "$HOME/Applications/LocalFlow.app" ]]; then
  backup=$(mktemp -d /tmp/localflow-previous.XXXXXX)
  mv "$HOME/Applications/LocalFlow.app" "$backup/LocalFlow.app"
fi
mv "$staging/LocalFlow.app" "$HOME/Applications/LocalFlow.app"
rmdir "$staging"
open "$HOME/Applications/LocalFlow.app"
