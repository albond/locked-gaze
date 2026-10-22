#!/bin/bash
# Builds a WidgetKit module interface for the Controls target: the current SDK's interface plus
# the control size declarations WidgetKit exports without publishing them.
set -euo pipefail
out="${1:?usage: build-widgetkit-overlay.sh OUTPUT_DIR}"
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
source="$sdk/System/Library/Frameworks/WidgetKit.framework/Versions/A/Modules/WidgetKit.swiftmodule"
mkdir -p "$out/WidgetKit.swiftmodule"
for interface in "$source"/*.swiftinterface; do
    cat "$interface" "$root/scripts/widgetkit-spi.swiftinterface" > "$out/WidgetKit.swiftmodule/$(basename "$interface")"
done
