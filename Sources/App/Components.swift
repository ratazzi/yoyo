import AppKit
import SwiftUI

struct TimeZoneField: NSViewRepresentable {
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.addItems(withObjectValues: TimeZone.knownTimeZoneIdentifiers)
        field.completes = true; field.numberOfVisibleItems = 10
        field.placeholderString = "Search time zones, e.g. Europe/London"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Time Zone")
        return field
    }
    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != selection { field.stringValue = selection }
    }
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: TimeZoneField
        init(_ parent: TimeZoneField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSComboBox { parent.selection = field.stringValue }
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            if let field = notification.object as? NSComboBox, field.indexOfSelectedItem >= 0 {
                parent.selection = field.itemObjectValue(at: field.indexOfSelectedItem) as? String ?? ""
            }
        }
    }
}

struct ProgramIcon: View {
    let path: String
    var size: CGFloat = 36
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().interpolation(.high).frame(width: size, height: size)
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
            .shadow(color: .black.opacity(0.025), radius: 6, y: 2)
    }
}
