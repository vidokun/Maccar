#!/bin/bash
set -e

echo "==> [Maccar Legacy Audit & Cleanup]"
echo "Scanning for BetterDisplay, SidecarLauncher, SidecarOne, and headless-sidecar residue..."

TARGETS=(
    "/Applications/BetterDisplay.app"
    "$HOME/Applications/BetterDisplay.app"
    "/Applications/SidecarLauncher.app"
    "$HOME/Applications/SidecarLauncher.app"
    "/Applications/SidecarOne.app"
    "$HOME/Applications/SidecarOne.app"
)

REMOVED=0

for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
        echo "Found legacy target: $target"
        rm -rf "$target"
        echo "✓ Removed: $target"
        REMOVED=$((REMOVED + 1))
    fi
done

# Kill any lingering background daemon from older tools (bracketed patterns prevent self-match)
pkill -f "[B]etterDisplay" 2>/dev/null || true
pkill -f "[S]idecarLauncher" 2>/dev/null || true
pkill -f "[h]eadless-sidecar.*daemon\.sh" 2>/dev/null || true
pkill -f "[S]idecarOne" 2>/dev/null || true

# Check LaunchAgents
was_nullglob=$(shopt -p nullglob || true)
was_nocaseglob=$(shopt -p nocaseglob || true)
shopt -s nullglob nocaseglob
for agent in \
    "$HOME/Library/LaunchAgents/"*betterdisplay* \
    "$HOME/Library/LaunchAgents/"*sidecarlauncher* \
    "$HOME/Library/LaunchAgents/"*headless-sidecar* \
    "$HOME/Library/LaunchAgents/"*sidecarone*; do
    if [ -f "$agent" ]; then
        echo "Found legacy LaunchAgent: $agent"
        label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$agent" 2>/dev/null || true)
        if [ -n "$label" ]; then
            launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
        else
            launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null || true
        fi
        rm -f "$agent"
        echo "✓ Removed LaunchAgent: $agent"
        REMOVED=$((REMOVED + 1))
    fi
done
eval "$was_nullglob"
eval "$was_nocaseglob"

echo "==> Cleanup complete. Total items purged: $REMOVED"
echo "Maccar is now 100% standalone with zero external dependencies."
