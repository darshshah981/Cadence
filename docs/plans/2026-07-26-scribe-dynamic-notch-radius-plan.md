# Scribe Dynamic Notch Radius Plan

## Reference finding

DynamicNotch uses a shallow concave quadratic shoulder where the notch meets the
top screen edge. Its normal geometry keeps the outward top radius four points
smaller than the lower corner radius.

Cadence will reproduce that visual relationship with an independently written
SwiftUI shape. No DynamicNotch source is copied into Cadence.

## Change

1. Keep the Scribe surface's existing 17-point continuous lower corners.
2. Set each hardware-notch attachment shoulder to 13 points.
3. Replace the circular cubic shoulder with a shallow quadratic curve that
   leaves the screen edge horizontally and meets the notch body vertically.
4. Preserve the existing floating-capsule geometry on displays without a
   hardware notch.

## Verification

- Assert the 4-point radius relationship in the geometry tests.
- Run the focused notch presentation tests.
- Run the full test suite.
- Build, install, launch, and verify `Cadence Debug`.
