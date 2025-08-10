import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if let sender = NDISender(name: "Test Sender", width: 1280, height: 720) {
    print("✅ NDI sender criado com sucesso!")
} else {
    print("❌ Falha ao criar NDI sender!")
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
