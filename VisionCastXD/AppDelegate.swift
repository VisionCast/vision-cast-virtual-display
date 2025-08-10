import Cocoa
import ReSwift

enum AppDelegateAction: Action {
    case didFinishLaunching
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_: Notification) {
        let viewController = ScreenViewController()

        // Lê resolução custom ou usa default
        let defaults = UserDefaults.standard
        let requestedWidth: Int = defaults.integer(forKey: "customWidth") > 0 ? defaults.integer(forKey: "customWidth") : 1408
        let requestedHeight: Int = defaults.integer(forKey: "customHeight") > 0 ? defaults.integer(forKey: "customHeight") : 640

        // Busca escala da tela principal
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        let widthInPoints = CGFloat(requestedWidth) / scale
        let heightInPoints = CGFloat(requestedHeight) / scale

        // Inicializa a janela com tamanho já compensado em pontos
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: widthInPoints, height: heightInPoints),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Configura controller e propriedades
        window.contentViewController = viewController
        window.delegate = viewController
        window.title = "Vision Cast XD"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.contentMinSize = CGSize(width: 400, height: 300)
        window.contentMaxSize = CGSize(width: 3840, height: 2160)
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenNone)

        // Configura camadas e escala 1.0 para evitar redimensionamento automático
        window.contentView?.wantsLayer = true
        if let layer = window.contentView?.layer {
            layer.contentsScale = 1.0
            layer.rasterizationScale = 1.0
        }
        window.contentView?.wantsBestResolutionOpenGLSurface = false

        // Aplica resolução corrigida para pixels reais (ajusta o tamanho e centraliza)
        applyPixelPerfectResolution(width: requestedWidth, height: requestedHeight)

        window.makeKeyAndOrderFront(nil)

        // Logs para debug
        if let screen = window.screen {
            print("Window is on screen with frame: \(screen.frame)")
            print("Screen backing scale factor: \(screen.backingScaleFactor)")
        }
        print("Window backing scale: \(window.backingScaleFactor)")
        print("Window frame: \(window.frame)")
        print("Window content size: \(window.contentView?.frame.size ?? .zero)")

        // Configura menu
        let mainMenu = NSMenu()
        let mainMenuItem = NSMenuItem()
        let subMenu = NSMenu(title: "MainMenu")

        let resolutionItem = NSMenuItem(
            title: "Custom Resolution...",
            action: #selector(openCustomResolutionWindow),
            keyEquivalent: "r"
        )
        resolutionItem.target = self
        subMenu.addItem(resolutionItem)

        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        subMenu.addItem(quitMenuItem)
        mainMenuItem.submenu = subMenu
        mainMenu.items = [mainMenuItem]
        NSApplication.shared.mainMenu = mainMenu

        store.dispatch(AppDelegateAction.didFinishLaunching)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        return true
    }

    @objc func openCustomResolutionWindow() {
        let controller = CustomResolutionWindowController()
        controller.showWindow(nil)
    }

    func applyStoredResolution() {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: "customWidth")
        let height = defaults.integer(forKey: "customHeight")
        applyPixelPerfectResolution(width: width, height: height)
    }

    // Método que ajusta tamanho compensando backingScale e centraliza janela
    func applyPixelPerfectResolution(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard let screen = window.screen ?? NSScreen.main else {
            print("No screen available to determine backingScaleFactor.")
            return
        }

        let backingScale = screen.backingScaleFactor
        let scaledWidth = CGFloat(width) / backingScale
        let scaledHeight = CGFloat(height) / backingScale
        let newOrigin = window.frame.origin
        let frame = NSRect(origin: newOrigin, size: CGSize(width: scaledWidth, height: scaledHeight))

        window.setFrame(frame, display: true, animate: true)
        window.center()

        print("Requested size: \(width)x\(height)")
        print("Backing scale factor: \(backingScale)")
        print("Applied frame: \(window.frame)")
    }
}
