import SwiftUI

// MARK: - Teilen-Erweiterung „An Scoop senden“ (docs/system.md)
//
// iPhone und iPad: Die Erweiterung sendet selbst (Zugangsdaten aus der gemeinsamen Schlüsselbund-Gruppe) und
// legt die Sendung nur ab, wenn der Server nicht erreichbar ist. Mac: Sie legt immer ab und weckt die App,
// die sofort sendet. Die Oberfläche ist auf allen Geräten dieselbe (`ShareView`).

#if os(iOS)
import UIKit

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: ShareModel(context: extensionContext)))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
#else
import AppKit

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override func loadView() {
        let host = NSHostingView(rootView: ShareView(model: ShareModel(context: extensionContext))
            .frame(width: 440, height: 560))
        view = host
    }
}
#endif
