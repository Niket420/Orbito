#!/usr/bin/env bash
# Development helper for Whisper.
#
#   scripts/dev.sh setup     Create backend/.venv and install dependencies (incl. Whistle)
#   scripts/dev.sh app       Build and run the macOS app (it starts the backend itself)
#   scripts/dev.sh backend   Run only the backend in the foreground (127.0.0.1:8765)
#   scripts/dev.sh test      Run backend (pytest) and app (swift test) tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
VENV_PY="$BACKEND/.venv/bin/python"

setup() {
    if [[ ! -x "$VENV_PY" ]]; then
        python3 -m venv "$BACKEND/.venv"
    fi
    "$VENV_PY" -m pip install --quiet --upgrade pip
    "$VENV_PY" -m pip install --quiet -e "$BACKEND[speech,dev]"
    echo "Backend environment ready: $BACKEND/.venv"
}

require_venv() {
    [[ -x "$VENV_PY" ]] || { echo "Run 'scripts/dev.sh setup' first." >&2; exit 1; }
}

case "${1:-app}" in
    setup)
        setup
        ;;
    app)
        require_venv
        cd "$ROOT/macos"
        swift build
        exec "$(swift build --show-bin-path)/Whisper"
        ;;
    backend)
        require_venv
        cd "$BACKEND"
        exec "$VENV_PY" -m app.main
        ;;
    test)
        require_venv
        (cd "$BACKEND" && "$VENV_PY" -m pytest -q)
        (cd "$ROOT/macos" && swift test)
        ;;
    *)
        sed -n '2,8p' "$0"
        exit 1
        ;;
esac
