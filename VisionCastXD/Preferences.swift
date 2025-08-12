import Foundation

enum Preferences {
    private static let kFPS = "preferredFPS" // 30 ou 60
    private static let kHalfRes = "previewHalfRes" // Bool

    // Default 30 fps
    static var preferredFPS: Int {
        let v = UserDefaults.standard.integer(forKey: kFPS)
        return (v == 30 || v == 60) ? v : 30
    }

    static var previewHalfRes: Bool {
        UserDefaults.standard.bool(forKey: kHalfRes)
    }

    static func setPreferredFPS(_ fps: Int) {
        guard fps == 30 || fps == 60 else { return }
        UserDefaults.standard.set(fps, forKey: kFPS)
    }

    static func setPreviewHalfRes(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: kHalfRes)
    }
}
