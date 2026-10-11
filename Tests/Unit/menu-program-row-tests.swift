import AppKit

@MainActor
final class MenuActionProbe: NSObject {
    var selected = false
    @objc func select(_ sender: Any?) { selected = true }
}

@main
struct MenuProgramRowTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func render(_ row: MenuProgramRow, into bitmap: NSBitmapImageRep? = nil) -> NSBitmapImageRep {
            let output = bitmap ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 30,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
            row.draw(row.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return output
        }
        let selection = MenuRowSelection()
        let first = MenuProgramRow(title: "First", icon: nil, running: false, selection: selection)
        let second = MenuProgramRow(title: "Second", icon: nil, running: false, selection: selection)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        first.mouseEntered(with: event)
        let previous = render(first)
        assert(previous.colorAt(x: 4, y: 15)!.alphaComponent > 0.5)
        // Menu tracking may deliver the next enter without a matching exit.
        second.mouseEntered(with: event)
        _ = render(first, into: previous)
        assert(previous.colorAt(x: 4, y: 15)!.alphaComponent < 0.1, "Previous row must lose its blue background")
        assert(render(second).colorAt(x: 4, y: 15)!.alphaComponent > 0.5)
        first.mouseExited(with: event) // A delayed exit must not clear the new row.
        assert(selection.selected === second)
        selection.menu(NSMenu(), willHighlight: nil)
        assert(render(second).colorAt(x: 4, y: 15)!.alphaComponent < 0.1)
        first.mouseEntered(with: event)
        selection.menuDidClose(NSMenu())
        assert(render(first).colorAt(x: 4, y: 15)!.alphaComponent < 0.1)
        for width in [320, 400, 520] {
            let view = MenuProgramRow(title: "Lark — Hong Kong", icon: nil, running: true)
            view.frame.size.width = CGFloat(width)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 30,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            var green: [Int] = []
            for x in 0..<width {
                for y in 0..<30 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.5 && color.greenComponent > color.redComponent * 1.4 && color.greenComponent > color.blueComponent * 1.4 {
                        green.append(x)
                    }
                }
            }
            assert(!green.isEmpty)
            assert((13...15).contains(width - 1 - green.max()!))
        }
        let menu = NSMenu(); let probe = MenuActionProbe()
        let item = NSMenuItem(title: "Edit Rule", action: #selector(MenuActionProbe.select), keyEquivalent: "")
        item.target = probe; menu.addItem(item)
        let view = MenuProgramRow(title: item.title, icon: nil, running: false)
        view.item = item; item.view = view
        assert(view.accessibilityPerformPress() && probe.selected)
        print("Menu rows: running dot stays at right edge at 320/400/520pt; accessibility action reaches rule editor: PASS")
        print("Menu highlight: missing/delayed exit, keyboard clear, close/reopen and background erasure: PASS")
    }
}
