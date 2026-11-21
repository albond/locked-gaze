#include "LGGazeNaturalness.hpp"
#include <cassert>
#include <cstdio>
#include <vector>

using lg::GazeNaturalness;
static const double deg = 3.14159265358979323846 / 180.0;
static bool close(double a, double b, double eps = 1e-12) { return std::abs(a - b) <= eps; }

int main() {
    // Defaults leave the target exactly as the pipeline computed it.
    {
        GazeNaturalness n;
        for (int i = 0; i < 2000; i++) {
            double pitch = 0.013 * (i % 7), yaw = -0.021 * (i % 5), p = pitch, y = yaw;
            n.apply(1.0 / 30, i % 90 == 0, -0.2, 0.1, 1, 1, p, y);
            assert(p == pitch && y == yaw);
            assert(!n.isGlancing());
        }
    }
    // Strength blends the target toward the observed gaze and is clamped to 0...1.
    {
        GazeNaturalness n;
        double p = 0, y = 0;
        n.settings.strength = 0.8;
        n.apply(1.0 / 30, false, -0.20, 0.10, 1, 1, p, y);
        assert(close(p, -0.04) && close(y, 0.02));
        p = 0.05; y = 0;
        n.settings.strength = 0;
        n.apply(1.0 / 30, false, -0.20, 0.10, 1, 1, p, y);
        assert(close(p, -0.20) && close(y, 0.10));
        p = 0; y = 0;
        n.settings.strength = 7;
        n.apply(1.0 / 30, false, -0.20, 0.10, 1, 1, p, y);
        assert(p == 0 && y == 0);
        p = 0; y = 0;
        n.settings.strength = -3;
        n.apply(1.0 / 30, false, -0.20, 0.10, 1, 1, p, y);
        assert(close(p, -0.20) && close(y, 0.10));
    }
    // Look-aways: bounded, smooth, spaced as configured, and they return to the lens.
    {
        GazeNaturalness n;
        n.settings.lookAways = true;
        const double dt = 1.0 / 30;
        int glances = 0, glanceFrames = 0, frames = 30 * 600;
        bool was = false;
        double previousYaw = 0, maxStep = 0, maxYaw = 0, maxPitch = 0, gapStart = 0, minGap = 1e9, maxGap = 0, longest = 0, run = 0;
        for (int i = 0; i < frames; i++) {
            double p = 0, y = 0;
            n.apply(dt, false, -0.2, 0.0, 1, 1, p, y);
            maxStep = std::max(maxStep, std::abs(y - previousYaw));
            previousYaw = y;
            maxYaw = std::max(maxYaw, std::abs(y));
            maxPitch = std::max(maxPitch, std::abs(p));
            bool now = n.isGlancing();
            if (now) { glanceFrames++; run += dt; } else { assert(p == 0 && y == 0); }
            if (now && !was) { glances++; if (glances > 1) { double gap = i * dt - gapStart; minGap = std::min(minGap, gap); maxGap = std::max(maxGap, gap); } }
            if (!now && was) { gapStart = i * dt; longest = std::max(longest, run); run = 0; }
            was = now;
        }
        assert(glances >= 600 / 13 && glances <= 600 / 4);            // every 4-12 s plus the glance itself
        assert(minGap >= 4.0 - 2 * dt && maxGap <= 12.0 + 2 * dt);
        assert(longest <= 0.9 + 2 * dt);
        assert(maxYaw <= 4 * deg + 1e-9 && maxYaw >= 2 * deg);       // sideways, within the limit
        assert(maxPitch <= 0.35 * 4 * deg + 1e-9);
        assert(maxStep < 1.5 * deg);                                  // eased, never a jump (peak ~36 deg/s)
        assert(double(glanceFrames) / frames < 0.2);                  // mostly on the lens
        std::printf("PASS: %d glances in 10 min, gaps %.1f-%.1f s, longest %.2f s, peak yaw %.1f deg, max step %.2f deg\n",
                    glances, minGap, maxGap, longest, maxYaw / deg, maxStep / deg);
    }
    // No glance starts during a blink or while the correction is released.
    {
        GazeNaturalness n;
        n.settings.lookAways = true;
        for (int i = 0; i < 30 * 120; i++) {
            double p = 0, y = 0;
            n.apply(1.0 / 30, true, 0, 0, 1, 1, p, y);
            assert(!n.isGlancing() && p == 0 && y == 0);
        }
        n.reset();
        for (int i = 0; i < 30 * 120; i++) {
            double p = 0.3, y = -0.2;
            n.apply(1.0 / 30, false, 0.3, -0.2, 0.2, 0.2, p, y);
            assert(!n.isGlancing() && p == 0.3 && y == -0.2);
        }
        // A glance in progress scales with engagement, so a released axis is untouched.
        n.reset();
        bool seen = false;
        for (int i = 0; i < 30 * 60 && !seen; i++) {
            double p = 0, y = 0;
            n.apply(1.0 / 30, false, 0, 0, 1, 1, p, y);
            if (n.isGlancing()) {
                double p2 = 0.1, y2 = 0.2;
                GazeNaturalness copy = n;
                copy.apply(1.0 / 30, false, 0.1, 0.2, 0, 0, p2, y2);
                assert(p2 == 0.1 && y2 == 0.2);
                seen = true;
            }
        }
        assert(seen);
    }
    // Bad time steps are tolerated; the same seed gives the same sequence; turning it off stops at once.
    {
        GazeNaturalness a(42), b(42);
        a.settings.lookAways = b.settings.lookAways = true;
        std::vector<double> dts = {1.0 / 30, 0, -1, 1e9, NAN, INFINITY, 1.0 / 15};
        for (int i = 0; i < 20000; i++) {
            double pa = 0, ya = 0, pb = 0, yb = 0, dt = dts[i % dts.size()];
            a.apply(dt, false, 0, 0, 1, 1, pa, ya);
            b.apply(dt, false, 0, 0, 1, 1, pb, yb);
            assert(std::isfinite(pa) && std::isfinite(ya) && pa == pb && ya == yb);
            assert(std::abs(ya) <= 4 * deg + 1e-9);
        }
        a.settings.lookAways = false;
        double p = 0, y = 0;
        a.apply(1.0 / 30, false, 0, 0, 1, 1, p, y);
        assert(p == 0 && y == 0 && !a.isGlancing());
    }
    std::printf("PASS: defaults are a no-op; strength blends and clamps; glances respect blink, engagement, bad time steps and seeds\n");
    return 0;
}
