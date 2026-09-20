#!/bin/bash
# Offline tests: synthetic data only; no camera permission or recording.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/stability
[[ -f build/deps/opencv/lib/libopencv_calib3d.a ]] || bash scripts/build-opencv.sh
xcrun clang++ -std=c++17 -fobjc-arc -fmodules -arch arm64 -mmacosx-version-min=14.0 -O1 \
    -I Native/include -I build/deps/opencv/include/opencv4 \
    -c Native/LGFramePipeline.mm -o build/stability/LGFramePipeline.o
native=(build/stability/LGFramePipeline.o -L build/deps/opencv/lib -L build/deps/opencv/lib/opencv4/3rdparty
    -lopencv_calib3d -lopencv_features2d -lopencv_flann -lopencv_imgproc -lopencv_core -ltegra_hal
    -lc++ -lz -framework Foundation -framework CoreVideo -framework CoreML -framework Accelerate)
swift=(-swift-version 5 -Onone -target arm64-apple-macos14.0)
run() {
    echo "== $1 =="
    python3 - "$@" <<'PYTEST'
import subprocess, sys
subprocess.run(["build/stability/" + sys.argv[1], *sys.argv[2:]], check=True, timeout=180)
PYTEST
}
xcrun swiftc "${swift[@]}" Sources/Core/LatestFrameWorker.swift Tests/FrameWorkerTests/main.swift -o build/stability/FrameWorkerTests
run FrameWorkerTests
xcrun swiftc "${swift[@]}" Sources/Core/ReplyOnce.swift Tests/ReplyOnceTests/main.swift -o build/stability/ReplyOnceTests
run ReplyOnceTests
xcrun swiftc "${swift[@]}" Sources/Core/GazeError.swift Sources/Core/CameraSelection.swift Sources/Shared/FrameMailbox.swift Tests/PolicyTests/main.swift -o build/stability/PolicyTests
run PolicyTests
xcrun swiftc "${swift[@]}" -parse-as-library Sources/Core/PermissionGate.swift Tests/PermissionTests/main.swift -o build/stability/PermissionTests
run PermissionTests
xcrun swiftc "${swift[@]}" -parse-as-library Sources/Core/GazeError.swift Sources/Core/CameraLifecycle.swift Tests/LifecycleTests/main.swift -o build/stability/LifecycleTests
run LifecycleTests
xcrun swiftc "${swift[@]}" -parse-as-library Sources/Core/GazeError.swift Sources/Core/StartupRetry.swift Tests/StartupRetryTests/main.swift -o build/stability/StartupRetryTests
run StartupRetryTests
xcrun swiftc "${swift[@]}" -parse-as-library Sources/Core/GazeError.swift Sources/Shared/CameraContract.swift Sources/App/ExtensionInstaller.swift Tests/ExtensionInstallerTests/main.swift -o build/stability/ExtensionInstallerTests
run ExtensionInstallerTests
xcrun swiftc "${swift[@]}" Sources/Core/GazeError.swift Sources/Core/CameraLifecycle.swift Sources/Core/CameraPresentation.swift Sources/App/Presentation.swift Tests/PresentationTests/main.swift -o build/stability/PresentationTests
run PresentationTests
xcrun swiftc "${swift[@]}" -import-objc-header Native/include/LGFramePipeline.h Tests/NativeTests/main.swift "${native[@]}" -o build/stability/NativeTests
run NativeTests
echo 'All nine source-only stability suites passed.'
