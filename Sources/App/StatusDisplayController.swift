import AppKit
import Combine

@MainActor
final class StatusDisplayController {
    private let item: NSStatusItem
    private let factory = ClockPresentationFactory()
    private var policy = PolicyDocument()
    private var preferences = DisplayPreferences()
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private let dockView = DockClockView()
    private let dockIconView = DockArtworkView()
    private let menuImage: NSImage?
    private var lastDockKey: String?

    init(store: AppStore, item: NSStatusItem) {
        self.item = item
        menuImage = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Timezone Lab")
        menuImage?.size = NSSize(width: 18, height: 18); menuImage?.isTemplate = true
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: nil), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        subscription = store.$policy.combineLatest(store.$displayPreferences).sink { [weak self] policy, preferences in
            guard let self else { return }
            self.policy = policy; self.preferences = preferences
            let activation: NSApplication.ActivationPolicy = preferences.showDockIcon ? .regular : .accessory
            if NSApp.activationPolicy() != activation { NSApp.setActivationPolicy(activation) }
            self.lastDockKey = nil
            self.refresh()
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    private func refresh() {
        let presentation = factory.make(policy: policy, preferences: preferences)
        if let label = presentation.label(for: preferences.menuBarContent) {
            item.button?.image = nil
            item.button?.attributedTitle = NSAttributedString(string: label,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
        } else {
            item.button?.title = ""
            item.button?.image = menuImage
        }
        item.button?.toolTip = presentation.tooltip
        item.button?.setAccessibilityLabel(presentation.label(for: preferences.menuBarContent) ?? "Timezone Lab")
        let dockKey = "\(preferences.showDockIcon):\(preferences.dockContent.rawValue):\(presentation.zoneIdentifier):\(presentation.label(for: preferences.dockContent) ?? "")"
        guard lastDockKey != dockKey else { return }
        lastDockKey = dockKey
        if preferences.showDockIcon && presentation.label(for: preferences.dockContent) != nil {
            dockView.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
            dockView.presentation = presentation; dockView.content = preferences.dockContent
            NSApp.dockTile.contentView = dockView
        } else if preferences.showDockIcon {
            dockIconView.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
            NSApp.dockTile.contentView = dockIconView
        } else { NSApp.dockTile.contentView = nil }
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }
}

@MainActor
private final class DockArtworkView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        TimezoneArtwork.flipClock(in: bounds)
    }
}

@MainActor
private final class DockClockView: NSView {
    var presentation: ClockPresentation?
    var content: ClockContent = .timeAndCity

    override func draw(_ dirtyRect: NSRect) {
        guard let presentation else { return }
        let size = min(bounds.width, bounds.height)
        TimezoneArtwork.tile(in: bounds)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        func draw(_ text: String, in rect: NSRect, font: NSFont) {
            (text as NSString).draw(in: rect, withAttributes: [.font: font,
                .foregroundColor: NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.21, alpha: 1), .paragraphStyle: paragraph])
        }
        draw("TZ", in: NSRect(x: size * 0.12, y: size * 0.69, width: size * 0.76, height: size * 0.15),
             font: .systemFont(ofSize: size * 0.12, weight: .semibold))
        if content == .city {
            draw(presentation.city, in: NSRect(x: size * 0.13, y: size * 0.33, width: size * 0.74, height: size * 0.3),
                 font: .systemFont(ofSize: size * 0.19, weight: .semibold))
        } else {
            let baseSize = size * 0.24
            let baseFont = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .medium)
            let measured = (presentation.time as NSString).size(withAttributes: [.font: baseFont]).width
            let timeSize = baseSize * min(1, size * 0.78 / max(1, measured))
            draw(presentation.time, in: NSRect(x: size * 0.10, y: size * 0.36, width: size * 0.80, height: size * 0.3),
                 font: .monospacedDigitSystemFont(ofSize: timeSize, weight: .medium))
            if content == .timeAndCity {
                draw(presentation.city, in: NSRect(x: size * 0.13, y: size * 0.20, width: size * 0.74, height: size * 0.17),
                     font: .systemFont(ofSize: size * 0.12, weight: .medium))
            }
        }
        setAccessibilityLabel(presentation.label(for: content) ?? "Timezone Lab")
    }
}
