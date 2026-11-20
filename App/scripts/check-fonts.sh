#!/bin/zsh
# Prüft, dass neue Oberflächen der Systemschriftgröße folgen (Dynamic Type, siehe App/README.md → „Schriftgröße“).
#
#   App/scripts/check-fonts.sh
#
# Meldet feste Schriftgrößen (`.system(size: …)`, `UIFont.systemFont(ofSize:)`, `NSFont.systemFont(ofSize:)`) in
# App, Shared und Teilen-Erweiterung außerhalb der kurzen Ausnahmeliste. Stattdessen:
#   - Text und Symbole neben Text: `.appFont(15, weight: .semibold)` bzw. `Font.app(15, in: dynamicTypeSize)`
#   - Dekoration, Figuren, aus der Geometrie abgeleitete Größen: `.font(.fixed(size * 0.44))`
# Exit-Code 1, wenn etwas gefunden wurde.
set -euo pipefail
cd "${0:A:h}/.."

# Ausnahmen (bewusst feste Größen):
#   AppFont.swift          – die zentrale Umsetzung selbst
#   Shared/Widget/         – Widgets: feste Flächen, das System skaliert Widgets nicht frei
#   AssetRenderer, MascotStyleSheet – nur Mac, rendern Icons und Prüfbögen als Bilder
#   AISBotWidgets, AISBotWatch*, ScoopsConnect – nicht geprüft (eigene Ziele, siehe README)
allow=(
  'Shared/Theme/AppFont.swift'
  'Shared/Widget/'
  'AISBot/Support/AssetRenderer.swift'
  'AISBot/Support/MascotStyleSheet.swift'
)

hits=$(grep -rnE '\.system\(size:|systemFont\(ofSize:' --include='*.swift' AISBot Shared AISBotShare || true)
for a in $allow; do
  hits=$(print -r -- "$hits" | grep -v "^$a" || true)
done
# Kommentare zählen nicht
hits=$(print -r -- "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [[ -n "$hits" ]]; then
  print -r -- "Feste Schriftgrößen gefunden (statt .appFont(…) bzw. .font(.fixed(…)) verwenden):"
  print -r -- "$hits"
  exit 1
fi
print "Schriftgrößen ok: keine festen Größen außerhalb der Ausnahmen."
