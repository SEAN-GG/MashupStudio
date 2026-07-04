import Foundation
import QuartzCore

/// Small NSObject wrapper so SwiftUI-world classes can drive a CADisplayLink with a closure.
final class DisplayLinkDriver: NSObject {
    private var link: CADisplayLink?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        callback()
    }

    deinit {
        link?.invalidate()
    }
}
