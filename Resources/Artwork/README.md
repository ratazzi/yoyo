# Dock artwork

`DockFlipClock-source.png` preserves the generated concept as a style reference only. It is not loaded by the app or the icon build.

`Sources/App/TimezoneArtwork.swift` draws the warm white tile, stepped flip panels, pedestal and custom bitmap digits with AppKit on a 64-unit grid. The paper tile occupies 86% of the canvas; the clock occupies about 84%. Static artwork uses 09:41, independent of the optional live clock. Both the running Dock icon and `scripts/render-app-icons.swift` use this renderer. Builds generate all macOS iconset sizes and a 1024px master directly from code. The menu bar keeps a separate transparent monochrome template at 18pt.
