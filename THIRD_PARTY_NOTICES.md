# Licensing and third-party notices

## Project code

Original Locked Gaze source code and accompanying documentation are provided
under the [MIT License](LICENSE), copyright 2026 albond, except where a file
or directory states different terms. Retain the copyright and permission
notice when redistributing MIT-covered material.

Model weights, compiled models, and model packages are not covered by this
MIT grant. Any separately supplied model artifacts require their own applicable
terms. The source-code license does not grant rights to third-party models,
datasets, trademarks, or services.

## OpenCV

The native pipeline uses OpenCV 4.12.0, licensed under Apache License 2.0.
The full license is preserved in [OpenCV-LICENSE.txt](LICENSES/OpenCV-LICENSE.txt).

- [OpenCV source](https://github.com/opencv/opencv/tree/4.12.0)
- [OpenCV licensing](https://opencv.org/license/)

## Carotene / Tegra HAL

The OpenCV build links its Carotene / Tegra HAL implementation. Applicable
BSD-style copyright and license headers are reproduced in
[Carotene-NOTICES.txt](LICENSES/Carotene-NOTICES.txt). This component retains
its own terms and is not relicensed under the project's MIT license.

## Apple frameworks

The application uses macOS frameworks including AppKit, SwiftUI, AVFoundation,
Core ML, Metal, Core Media I/O, IOSurface, WidgetKit, and App Intents. These
frameworks are supplied by Apple and are not relicensed by this repository.

## Redistribution

Keep the applicable third-party license texts and copyright notices with
redistributed source and binaries. Review the dependency inventory again when
changing the native build or preparing a release; this document does not
grant rights beyond the listed components' own terms.
