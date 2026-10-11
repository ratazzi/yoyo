# Dock artwork

`DockFlipClock-source.png` preserves the full generated pixel flip-clock concept on warm paper. The illustrated 09:41 is static artwork, independent of the optional live Dock clock.

`scripts/render-app-icons.swift` trims 13% from each source edge, clips it to a clean rounded tile, and renders it at 86% of the canvas. This enlarges the illustrated clock by about 19% compared with the original 6% trim, while keeping the paper tile the same size. It regenerates the full macOS iconset and 1024px master during builds. The menu bar keeps a separate transparent monochrome template at 18pt; it does not reuse the paper tile.
