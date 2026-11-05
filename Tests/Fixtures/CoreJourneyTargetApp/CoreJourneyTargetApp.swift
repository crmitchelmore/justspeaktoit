import AppKit

/// Stable Accessibility destination for the launched-app dictation journey.
@main
final class CoreJourneyTargetApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func main() {
        let application = NSApplication.shared
        let delegate = CoreJourneyTargetApp()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let field = NSTextView(frame: NSRect(x: 24, y: 48, width: 592, height: 288))
        field.isEditable = true
        field.isRichText = false
        field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        field.setAccessibilityIdentifier("coreJourneyTargetField")
        field.setAccessibilityLabel("Core journey target field")

        let scrollView = NSScrollView(frame: field.frame)
        scrollView.documentView = field
        scrollView.hasVerticalScroller = true
        scrollView.setAccessibilityIdentifier("coreJourneyTargetScrollView")

        let status = NSTextField(labelWithString: "Fixture ready")
        status.frame = NSRect(x: 24, y: 16, width: 592, height: 20)
        status.setAccessibilityIdentifier("coreJourneyFixtureStatus")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        content.addSubview(scrollView)
        content.addSubview(status)

        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Core Journey Target"
        window.contentView = content
        window.setAccessibilityIdentifier("coreJourneyTargetWindow")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Without a main menu AppKit has nowhere to route Command-V, so a paste
    /// keystroke would never reach the text view the way it does in real editors.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Core Journey Target", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }
}
