#pragma once
// Optional softening of the gaze target. Plain C++ with no dependencies, so the
// logic is testable without OpenCV, Core ML or a camera.
//
// The pipeline aims the eyes at the camera (target 0, 0). Two adjustments make
// that read less like a fixed stare:
//  - strength below 1 leaves a share of the observed eye movement in place;
//  - look-aways add a brief glance a few degrees off the lens at random
//    intervals, easing out and back while the correction stays on.
// With strength 1 and look-aways off, apply() leaves the target untouched.
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace lg {

struct GazeNaturalnessSettings {
    double strength = 1.0;       // 0...1; 1 aims fully at the camera
    bool lookAways = false;
    double minInterval = 4.0;    // seconds between glances
    double maxInterval = 12.0;
    double minDuration = 0.35;   // seconds for one glance, out and back
    double maxDuration = 0.9;
    double maxAngle = 4.0 * 3.14159265358979323846 / 180.0;  // radians
};

class GazeNaturalness {
public:
    GazeNaturalnessSettings settings;

    explicit GazeNaturalness(std::uint64_t seed = 0x9E3779B97F4A7C15ull) { reset(seed); }

    void reset(std::uint64_t seed = 0x9E3779B97F4A7C15ull) {
        state_ = seed ? seed : 1;
        glancing_ = false;
        progress_ = 0;
        untilNext_ = -1;
    }

    bool isGlancing() const { return glancing_; }

    /// Angles are radians. `engagement` is 0...1 per axis, where 1 means the axis is
    /// fully corrected and 0 means the observed gaze is passed through (blink, large
    /// gaze or head angle). `dt` is the time since the previous frame in seconds.
    void apply(double dt, bool blink, double observedPitch, double observedYaw,
               double engagementPitch, double engagementYaw,
               double &targetPitch, double &targetYaw) {
        const double strength = std::clamp(settings.strength, 0.0, 1.0);
        if (strength < 1.0) {
            targetPitch += (1.0 - strength) * (observedPitch - targetPitch);
            targetYaw += (1.0 - strength) * (observedYaw - targetYaw);
        }
        if (!settings.lookAways) {
            glancing_ = false;
            untilNext_ = -1;
            return;
        }
        if (!std::isfinite(dt) || dt < 0) dt = 0;
        dt = std::min(dt, 0.25);  // a stalled frame must not skip a whole glance
        engagementPitch = std::clamp(engagementPitch, 0.0, 1.0);
        engagementYaw = std::clamp(engagementYaw, 0.0, 1.0);
        if (untilNext_ < 0) untilNext_ = interval();

        if (!glancing_) {
            untilNext_ -= dt;
            // Start only while the eyes are open and the correction is clearly on, so a
            // glance never begins on a frame where the real gaze is already showing.
            if (untilNext_ <= 0 && !blink && std::min(engagementPitch, engagementYaw) > 0.5) {
                glancing_ = true;
                progress_ = 0;
                duration_ = uniform(settings.minDuration, std::max(settings.minDuration, settings.maxDuration));
                const double side = next() < 0.5 ? -1.0 : 1.0;
                offsetYaw_ = side * uniform(0.5, 1.0) * settings.maxAngle;      // mostly sideways
                offsetPitch_ = uniform(-0.35, 0.35) * settings.maxAngle;
            }
        }
        if (glancing_) {
            progress_ += dt / std::max(duration_, 1e-3);
            if (progress_ >= 1.0) {
                glancing_ = false;
                untilNext_ = interval();
            } else {
                const double s = std::sin(3.14159265358979323846 * progress_);
                const double envelope = s * s;  // 0 -> 1 -> 0 with zero slope at both ends
                targetPitch += envelope * engagementPitch * offsetPitch_;
                targetYaw += envelope * engagementYaw * offsetYaw_;
            }
        }
    }

private:
    double next() {  // xorshift64*, uniform in [0, 1)
        state_ ^= state_ >> 12;
        state_ ^= state_ << 25;
        state_ ^= state_ >> 27;
        return double((state_ * 0x2545F4914F6CDD1Dull) >> 11) / 9007199254740992.0;
    }
    double uniform(double lo, double hi) { return lo + (hi - lo) * next(); }
    double interval() { return uniform(settings.minInterval, std::max(settings.minInterval, settings.maxInterval)); }

    std::uint64_t state_ = 1;
    bool glancing_ = false;
    double progress_ = 0, duration_ = 0.5, untilNext_ = -1;
    double offsetPitch_ = 0, offsetYaw_ = 0;
};

}  // namespace lg
