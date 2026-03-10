#!/usr/bin/env bash
set -euo pipefail

RIME_DIR="${1:-$HOME/Library/Rime}"
GLOSSARY_FILE="${2:-$HOME/.hammerspoon/prompts/glossary.txt}"

if [[ ! -d "$RIME_DIR" ]]; then
  echo "Rime dir not found: $RIME_DIR" >&2
  exit 1
fi

TMP_SECTION="$(mktemp)"
GLOSSARY_TMP=""
cleanup() {
  rm -f "$TMP_SECTION"
  if [[ -n "${GLOSSARY_TMP:-}" ]]; then
    rm -f "$GLOSSARY_TMP"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$(dirname "$GLOSSARY_FILE")"
GLOSSARY_TMP="$(mktemp "$(dirname "$GLOSSARY_FILE")/.glossary.sync.XXXXXX")"

extract_terms() {
  local file="$1"
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    {
      if (index($0, "\t") > 0) {
        split($0, a, "\t");
        term = a[1];
      } else {
        split($0, a, /[[:space:]]+/);
        term = a[1];
      }
      if (term != "") print term;
    }
  ' "$file" | awk '!seen[$0]++'
}

{
  echo "# === AUTO:RIME BEGIN ==="
  for name in custom_phrase_double.txt custom_phrase.txt custom_dict.txt custom_eng.txt airbag_terms.txt; do
    path="$RIME_DIR/$name"
    if [[ -f "$path" ]]; then
      echo "# source: $name"
      extract_terms "$path"
    else
      echo "# source: $name (missing)"
    fi
  done
  echo "# === AUTO:RIME END ==="
} > "$TMP_SECTION"

if [[ -f "$GLOSSARY_FILE" ]]; then
  if grep -q "^# === AUTO:RIME BEGIN ===" "$GLOSSARY_FILE"; then
    awk -v section="$TMP_SECTION" '
      BEGIN {
        while ((getline line < section) > 0) {
          sec = sec line "\n";
        }
        close(section);
      }
      {
        if ($0 == "# === AUTO:RIME BEGIN ===") {
          printf "%s", sec;
          in_section = 1;
          next;
        }
        if (in_section && $0 == "# === AUTO:RIME END ===") {
          in_section = 0;
          next;
        }
        if (!in_section) print;
      }
    ' "$GLOSSARY_FILE" > "$GLOSSARY_TMP"
  else
    cat "$GLOSSARY_FILE" > "$GLOSSARY_TMP"
    printf "\n" >> "$GLOSSARY_TMP"
    cat "$TMP_SECTION" >> "$GLOSSARY_TMP"
  fi
else
  cat "$TMP_SECTION" > "$GLOSSARY_TMP"
fi

mv "$GLOSSARY_TMP" "$GLOSSARY_FILE"
GLOSSARY_TMP=""

lines=$(grep -A9999 "^# === AUTO:RIME BEGIN ===" "$GLOSSARY_FILE" | wc -l | awk '{print $1}')
echo "Synced Rime glossary: $lines lines (auto section)"
