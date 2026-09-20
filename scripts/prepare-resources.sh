#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f build/deps/opencv/lib/libopencv_calib3d.a ]] || bash scripts/build-opencv.sh
bash scripts/build-icon.sh
if [[ "${LOCKED_GAZE_SOURCE_ONLY:-0}" == "1" ]]; then
    # Explicit compile-only mode: never stage model files into this build.
    rm -rf build/Models
    mkdir -p build/Models
    echo "Source-only build: gaze correction requires separately supplied models."
else
    bash scripts/stage-models.sh "${LOCKED_GAZE_MODELS_PATH:-Models/Compiled}"
fi
mkdir -p build/Models/Licenses
cp LICENSES/*.txt build/Models/Licenses/
