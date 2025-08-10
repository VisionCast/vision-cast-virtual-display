import Cocoa

class CustomResolutionWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSMakeRect(0, 0, 300, 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        self.init(window: window)
        contentViewController = CustomResolutionViewController()
        self.window?.title = "Custom Resolution"
    }
}
