#!/bin/bash
# Run Substrata engine tests in headless mode.
#
# Usage: ./tests/run_tests.sh [path/to/godot]
#
# Temporarily sets the test scene as the main scene, runs headless,
# then restores the original main scene.

set -e

GODOT="${1:-godot}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$PROJECT_DIR/project.godot"

# Save original main scene line
ORIGINAL_LINE=$(grep 'run/main_scene=' "$PROJECT_FILE")

# Set test scene as main scene
sed -i '' 's|run/main_scene=.*|run/main_scene="res://tests/test_runner.tscn"|' "$PROJECT_FILE"

# Ensure we restore the original main scene on exit (even on failure)
restore() {
    sed -i '' "s|run/main_scene=.*|${ORIGINAL_LINE}|" "$PROJECT_FILE"
}
trap restore EXIT

# Import project (needed if first run)
"$GODOT" --headless --path "$PROJECT_DIR" --import 2>/dev/null || true

# Run tests
"$GODOT" --headless --path "$PROJECT_DIR" --quit-after 5 2>&1
