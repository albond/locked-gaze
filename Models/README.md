# Model interface specification

This source edition contains no model weights, compiled models, model packages,
trained head coefficients, or model-derived fixtures. Supply your own compatible
models to enable gaze correction. Tensor shapes alone do not guarantee compatible
semantics or visual quality. The encoder and decoder must be a matched pair.

The contracts below describe the current native consumer, not a training recipe.
All inputs are batch-one, row-major Float32 `MLMultiArray` values. Image tensors
use NCHW order. Unless explicitly noted, outputs are Float32 as well. All values
returned to the native pipeline must be finite. No network inference is used.

## 1. Face detector (`face`)

| Direction | Logical feature | Shape | Meaning |
| --- | --- | --- | --- |
| Input | `input` | `[1, 3, 208, 368]` | BGR image, each component divided by 255 |
| Output | `output_bbox` | `[1, 4, 13, 23]` | Left, top, right, bottom distances from grid anchors, scaled by 35 |
| Output | `output_cov/Sigmoid` | `[1, 1, 13, 23]` | Face probability per grid location |

The input frame is aspect-fit into 368 × 208 with black letterbox padding.
Resize dimensions round to the nearest integer. Upsampling uses Lanczos4;
downsampling uses area interpolation. At grid `(x, y)`, the anchor is
`(16*x + 0.5, 16*y + 0.5)`. Bounding box corners are:

```text
left   = 16*x + 0.5 - 35*bbox[0,y,x]
top    = 16*y + 0.5 - 35*bbox[1,y,x]
right  = 16*x + 0.5 + 35*bbox[2,y,x]
bottom = 16*y + 0.5 + 35*bbox[3,y,x]
```

Coverage below 0.1 is ignored. The consumer clusters overlapping detections and
selects a face, then converts coordinates back into the original frame.
The existing loader requires `compute_precision` to be `fp32` for this model.

## 2. Facial landmarks (`landmarks`)

| Direction | Logical feature | Shape | Meaning |
| --- | --- | --- | --- |
| Input | `input` | `[1, 1, 160, 160]` | Grayscale cropped face, values in the 0–255 range |
| Output | `kpts` | `[1, 136]` | 68 x coordinates followed by 68 y coordinates |
| Output | `confidence` | `[1, 68]` | Per-landmark confidence, intended range 0–1 |

The selected square face crop is padded with black outside the frame and
letterboxed to 160 × 160. Grayscale uses OpenCV BGR-to-gray conversion on
Float32 values; there is no division by 255. Coordinates are in pixels in this
160 × 160 input, before inverse letterbox/crop transformation.

The ordering is the conventional 68-point face layout: jaw 0–16, eyebrows
17–26, nose 27–35, eyes 36–47, mouth 48–67. Eyelid contours 36–41 and 42–47
are especially important. Mean confidence at or below 0.15 bypasses correction.
The loader also accepts an optional `headpose` output `[1, 3]`, which the native
pipeline does not consume.

### Optional heatmap interface

A model may instead output Float16 `heatmaps` of shape `[1, 72, 160, 160]`,
using `native_head: "metal-moments-v1"` in both its sidecar and Core ML
creator-defined metadata. This requires a separately supplied
`landmarks.head.json`; no coefficients are distributed here.

The head schema is:

| Field | Required value or dimensions |
| --- | --- |
| `version` | `1` |
| `channels` | 72 distinct integer channel identifiers; describes supplied channel order |
| `width`, `height` | `160`, `160` |
| `alpha`, `threshold` | `0.01`, `0.00001` |
| `keypoint_weights`, `keypoint_bias` | `[136][144]`, `[136]` |
| `confidence_weights`, `confidence_bias` | `[68][72]`, `[68]` |
| `confidence_a`, `confidence_b` | `[72]`, `[72]`; each `a` must be nonzero |

Coefficients must be finite. Channel order is already fixed by the model;
the decoder does not reorder heatmaps using `channels`. It applies leaky ReLU,
spatial softmax, and drops probabilities below the threshold without
renormalizing. FP32 first and central moments produce 72 x/y pairs and summed
x/y variance. Scores are `1 - clamp((0.5*variance + b)/a, 0, 1)`. The supplied
linear maps produce the 136 coordinates and 68 confidences. SHA-256 of the exact
head JSON bytes must equal `head_sha256` in both the sidecar and model metadata.
Implementing the direct Float32 landmark interface avoids this optional head.

## 3. Eye-patch encoder (`encoder`)

| Direction | Logical feature | Shape | Meaning |
| --- | --- | --- | --- |
| Input | `input_image` | `[1, 3, 64, 256]` | RGB normalized eye patch, values 0–1 |
| Output | `embeddings_flat` | `[1, 1344]` | Latent representation consumed unchanged by the decoder |
| Output | `pseudo_labels_flat` | `[1, 12]` | Decoder conditioning; indices 10 and 11 are pitch and yaw in radians |

The input is a perspective-normalized patch of both eyes, width 256 and height
64. Native geometry estimates head pose from facial landmarks, uses a virtual
focal length of 1300 and normalization distance of 600, and samples the patch
with bilinear interpolation and black out-of-frame pixels. Exact transforms
are implemented in `Native/LGFramePipeline.mm`.

The remaining conditioning components and latent dimensions are opaque to the
host. Their meaning must agree between your encoder and decoder; the host
cannot make independently trained representations interchangeable.

## 4. Eye-patch decoder (`decoder`)

| Direction | Logical feature | Shape | Meaning |
| --- | --- | --- | --- |
| Input | `embeddings_flat` | `[1, 1344]` | Encoder latent representation |
| Input | `pseudo_labels_flat` | `[1, 12]` | Encoder conditioning vector |
| Input | `gaze_por` | `[1, 2]` | Desired pitch, yaw in radians |
| Output | `gaze_redirected_image` | `[1, 3, 64, 256]` | Corrected RGB eye patch, intended range 0–1 |
| Output | `gaze_landmarks` | `[1, 2, 12, 1]` | 12 eyelid x coordinates followed by 12 y coordinates |

A target near `[0, 0]` requests centered gaze. The host blends toward the
observed gaze during blinks and large head/gaze angles. Targets are not screen
pixels. The decoder must use the same pitch/yaw coordinate convention as the
encoder and native pose calculation.

Eyelid points correspond to face landmarks 36–47. Coordinates are centered
normalized patch coordinates: `pixel_x = (x + 0.5)*256` and
`pixel_y = (y + 0.5)*64`. Valid points stay inside the patch. The host combines
original and redirected eyelid masks, feathers them, and warps the corrected
residual into the original frame. Invalid geometry bypasses correction.

## Packaging and model identity

For each key (`face`, `landmarks`, `encoder`, `decoder`), provide
`<key>.mlmodelc` and `<key>.json` in a local directory. The staging script also
accepts `<key>.mlpackage` and compiles it with `coremlcompiler`.

Each JSON sidecar requires:

- `outputs`: a one-to-one mapping from the logical output names above to the
  actual Core ML output feature names.
- `source_sha256`: the identity of your source model.
- `adapted_sha256`: a 64-character digest matching the adapted model metadata.
- `compute_precision`: `fp32`, `fp16`, or `mixed` (face requires `fp32`).

Input feature names must match exactly; an `inputs` mapping is not read by the
loader. Core ML creator-defined metadata must contain the same `source_sha256`,
`adapted_sha256`, and `compute_precision` values. These provenance fields are
consistency checks, not a cryptographic signature of all compiled bundle files.

`ModelStore.sourceHashes` currently pins expected model identities. For your own
models, deliberately replace those pins with your own source digests, and set
matching metadata and sidecars. Do not label a replacement as another model or
remove shape/type validation. This repository does not supply a downloadable
model matching the existing pins.

## Compiling the source edition

Use Apple Silicon, Xcode with the macOS 26 SDK or later (for the Controls target),
Python 3 for project generation, and CMake for building the pinned OpenCV
dependency. These build tools are not runtime inference dependencies.

A compile-only build contains no models and cannot perform gaze correction:

```sh
python3 scripts/generate-project.py
LOCKED_GAZE_SOURCE_ONLY=1 xcodebuild -project LockedGaze.xcodeproj \
  -scheme LockedGaze -configuration Release -derivedDataPath build/SourceOnly \
  CODE_SIGNING_ALLOWED=NO build
bash scripts/test-source.sh
```

The tests use synthetic buffers and fake providers, without camera capture or
model weights. They do not validate correction quality or hardware compatibility.

For a functional build, omit `LOCKED_GAZE_SOURCE_ONLY`, set
`LOCKED_GAZE_MODELS_PATH` to your local compatible model directory, and configure
your own signing team in the ignored `Config/Signing.local.xcconfig`. Camera
extension testing requires suitable signing/provisioning and installation at
`/Applications/Locked Gaze.app`; an unsigned compile-only artifact is not a
camera-test build. Validate your models and their distribution terms separately.
