#!/bin/bash
# Stage compiled resources, or compile an explicitly selected local candidate.
set -euo pipefail
cd "$(dirname "$0")/.."
models="${1:-Models/Compiled}"
mkdir -p build
staging=$(mktemp -d "$PWD/build/model-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
for key in face landmarks encoder decoder; do
    if [[ -d "$models/$key.mlmodelc" ]]; then
        cp -R "$models/$key.mlmodelc" "$staging/"
    elif [[ -d "$models/$key.mlpackage" ]]; then
        xcrun coremlcompiler compile "$models/$key.mlpackage" "$staging" > "build/$key-coreml.log" 2>&1
    else
        echo "Missing model: $models/$key. See Models/README.md for the interface contract; no weights are downloaded automatically." >&2
        exit 1
    fi
    cp "$models/$key.json" "$staging/"
    if [[ -f "$models/$key.head.json" ]]; then cp "$models/$key.head.json" "$staging/"; fi
done
if [[ -f "$models/OpenCV-LICENSE.txt" ]]; then
    cp "$models/OpenCV-LICENSE.txt" "$staging/"
else
    cp LICENSES/OpenCV-LICENSE.txt "$staging/OpenCV-LICENSE.txt"
fi
# Replace only generated staging output, avoiding stale candidate resources.
rm -rf build/Models
mv "$staging" build/Models
