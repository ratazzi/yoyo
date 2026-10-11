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
        func render(_ row: MenuRowView, into bitmap: NSBitmapImageRep? = nil) -> NSBitmapImageRep {
            let output = bitmap ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(row.bounds.width), pixelsHigh: Int(row.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
            row.draw(row.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return output
        }
        let selection = MenuRowSelection()
        let first = MenuRowView(name: "First", detail: .program(zone: "Tokyo", running: false), icon: nil, selection: selection)
        let second = MenuRowView(name: "Second", detail: .program(zone: "Hong Kong", running: false), icon: nil, selection: selection)
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
            let view = MenuRowView(name: "Lark", detail: .program(zone: "Hong Kong", running: true), icon: nil)
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
            func ink(_ bitmap: NSBitmapImageRep, from start: Int, to end: Int) -> [Int] {
                (start..<end).filter { x in
                    (0..<bitmap.pixelsHigh).contains { y in bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.15 }
                }
            }
            var rightEdges: [Int] = []
            for offset in ["+11", "+09", "−04", "+05:45"] {
                let clock = MenuRowView(name: "Lark", detail: .timeZone(time: "H", offset: offset), icon: nil)
                clock.frame.size.width = CGFloat(width)
                let clockBitmap = render(clock)
                let clockStart = ink(clockBitmap, from: width - 164, to: width - 100).min()!
                let program = MenuRowView(name: "Lark", detail: .program(zone: "H", running: false), icon: nil)
                program.frame.size.width = CGFloat(width)
                let programStart = ink(render(program), from: width - 164, to: width - 100).min()!
                assert(abs(clockStart - programStart) <= 2, "Time and program zone must share the same column")
                let last = ink(clockBitmap, from: width - 80, to: width).max()!
                assert((13...18).contains(width - 1 - last), "UTC offset must follow the actual right edge")
                rightEdges.append(last)
            }
            assert(rightEdges.max()! - rightEdges.min()! <= 2)
        }
        let menu = NSMenu(); let probe = MenuActionProbe()
        let item = NSMenuItem(title: "Edit Rule", action: #selector(MenuActionProbe.select), keyEquivalent: "")
        item.target = probe; menu.addItem(item)
        let view = MenuRowView(name: item.title, detail: .program(zone: "Tokyo", running: false), icon: nil)
        view.item = item; item.view = view
        assert(view.accessibilityPerformPress() && probe.selected)
        print("Menu rows: running dot stays at right edge at 320/400/520pt; accessibility action reaches rule editor: PASS")
        print("Menu highlight: missing/delayed exit, keyboard clear, close/reopen and background erasure: PASS")
        print("Shared menu columns: time/program zone alignment and right-aligned UTC offsets at all widths: PASS")
    }
}
