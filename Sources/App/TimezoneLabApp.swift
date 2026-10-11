import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: AppStore!
    private var item: NSStatusItem!
    private var window: NSWindow!
    private var promptWindow: NSPanel?
    private var activePromptID: String?
    private var observation: AnyCancellable?
    private var statusDisplay: StatusDisplayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TZ"
        let menu = NSMenu()
        for (title, action, key) in [("Open Timezone Lab", #selector(showMain), ""), ("Settings…", #selector(showSettings), ","),
                                    ("Find Program…", #selector(focusSearch), "f")] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Timezone Lab", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        item.menu = menu
        statusDisplay = StatusDisplayController(store: store, item: item)
        let appMenu = NSMenu(); let parent = NSMenuItem(); parent.submenu = menu.copy() as? NSMenu; appMenu.addItem(parent)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu; appMenu.addItem(editItem); NSApp.mainMenu = appMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Timezone Lab"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 700, height: 460)
        window.contentView = NSHostingView(rootView: DashboardView(store: store).ignoresSafeArea())
        window.setFrameAutosaveName("TimezoneLabMainWindow"); window.center()
        observation = store.$prompts.sink { [weak self] prompts in
            // Published notifications precede assignment. Present on the next main turn.
            DispatchQueue.main.async { self?.presentPrompt(prompts.first) }
        }
        showMain()
    }
    @objc func showMain() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func showSettings() { showMain(); store.showingSettings = true }
    @objc func focusSearch() { showMain(); NotificationCenter.default.post(name: .init("FocusProgramSearch"), object: nil) }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func presentPrompt(_ prompt: LaunchPrompt?) {
        guard prompt?.id != activePromptID else { return }
        promptWindow?.orderOut(nil); promptWindow = nil; activePromptID = prompt?.id
        guard let prompt else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 696, height: 456), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Timezone Lab Launch Request"; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: LaunchPromptView(store: store, prompt: prompt))
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center(); NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); promptWindow = panel
    }
}

@main
struct TimezoneLabApp {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
