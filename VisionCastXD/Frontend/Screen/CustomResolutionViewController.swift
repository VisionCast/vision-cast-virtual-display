import Cocoa

class CustomResolutionViewController: NSViewController {
    let widthField = NSTextField()
    let heightField = NSTextField()
    let appDelegate = NSApplication.shared.delegate as? AppDelegate

    override func loadView() {
        view = NSView(frame: NSMakeRect(0, 0, 300, 160))

        let widthLabel = NSTextField(labelWithString: "Width:")
        widthLabel.frame = NSRect(x: 20, y: 100, width: 80, height: 24)
        widthField.frame = NSRect(x: 110, y: 100, width: 150, height: 24)

        let heightLabel = NSTextField(labelWithString: "Height:")
        heightLabel.frame = NSRect(x: 20, y: 60, width: 80, height: 24)
        heightField.frame = NSRect(x: 110, y: 60, width: 150, height: 24)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveResolution))
        saveButton.frame = NSRect(x: 110, y: 20, width: 80, height: 30)

        // Load existing
        let defaults = UserDefaults.standard
        let w = defaults.integer(forKey: "customWidth")
        let h = defaults.integer(forKey: "customHeight")
        widthField.stringValue = w > 0 ? String(w) : "1920"
        heightField.stringValue = h > 0 ? String(h) : "1080"

        view.addSubview(widthLabel)
        view.addSubview(widthField)
        view.addSubview(heightLabel)
        view.addSubview(heightField)
        view.addSubview(saveButton)
    }

    @objc func saveResolution() {
        guard
            let width = Int(widthField.stringValue),
            let height = Int(heightField.stringValue),
            width > 0, height > 0
        else {
            NSSound.beep()
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(width, forKey: "customWidth")
        defaults.set(height, forKey: "customHeight")
        defaults.set(true, forKey: "useCustomResolution")

        // Aplica imediatamente
        appDelegate?.applyStoredResolution()

        view.window?.close()
    }
}
