#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="build.noindex/Build/Products/${CONFIGURATION:-Release}/LocalFlow.app"
[[ -d "$app" ]] || { echo 'Run Scripts/build.sh first'; exit 1; }
if pgrep -f '^.*/LocalFlow[.]app/Contents/MacOS/LocalFlow$' >/dev/null; then
  echo 'Сначала завершите LocalFlow через меню приложения, затем повторите установку.'
  exit 1
fi
identity_file="$HOME/Library/Application Support/LocalFlow/Signing/ready"
[[ -f "$identity_file" ]] || { echo 'Сначала запустите Scripts/build.sh для сборки с постоянной подписью.'; exit 1; }
identity=$(<"$identity_file")
[[ "$identity" =~ '^[0-9A-Fa-f]{40}$' ]] || { echo 'Повреждена запись локальной подписи.'; exit 1; }
codesign --verify --deep --strict -R="identifier com.beiev.localflow and certificate root = H\"$identity\"" "$app"
mkdir -p "$HOME/Applications"
staging=$(mktemp -d "$HOME/Applications/.localflow-install.XXXXXX")
ditto "$app" "$staging/LocalFlow.app"
codesign --verify --deep --strict "$staging/LocalFlow.app"
if [[ -d "$HOME/Applications/LocalFlow.app" ]]; then
  backup=$(mktemp -d /tmp/localflow-previous.XXXXXX)
  mv "$backup" "$backup.noindex"
  backup="$backup.noindex"
  mv "$HOME/Applications/LocalFlow.app" "$backup/LocalFlow.app"
fi
mv "$staging/LocalFlow.app" "$HOME/Applications/LocalFlow.app"
rmdir "$staging"
registrar=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$registrar" -u "$PWD/$app" || true
"$registrar" -f "$HOME/Applications/LocalFlow.app"
if [[ "${LOCALFLOW_NO_LAUNCH:-0}" != 1 ]]; then open "$HOME/Applications/LocalFlow.app"; fi
