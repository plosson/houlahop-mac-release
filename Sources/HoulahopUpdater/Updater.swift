import Combine
import Sparkle
import SwiftUI

/// Checks the app's Sparkle feed (SUFeedURL in Info.plist) for updates in the background, and backs the
/// "Check for Updates…" menu item. Create one per app and keep it for the app's lifetime.
@MainActor
public final class Updater: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    public init() {
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" menu item, disabled while a check is already running.
public struct CheckForUpdatesButton: View {
    @ObservedObject private var updater: Updater

    public init(updater: Updater) {
        self.updater = updater
    }

    public var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
