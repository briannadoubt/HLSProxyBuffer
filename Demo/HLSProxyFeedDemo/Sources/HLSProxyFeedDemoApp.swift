import SwiftUI

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import UIKit
#endif

@main
struct HLSProxyFeedDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: FeedDemoModel

#if canImport(BackgroundTasks) && os(iOS)
    @UIApplicationDelegateAdaptor(FeedDemoAppDelegate.self) private var appDelegate
#endif

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let synthetic = arguments.contains("--qualification-mode") || arguments.contains("--synthetic-media")
        let qualification = arguments.contains("--qualification-mode")
            || arguments.contains("--vertical-qualification-mode")
        let model = FeedDemoModel(
            mediaConfiguration: synthetic ? .synthetic : .realMedia,
            cacheScope: qualification ? .freshQualification : .persistent
        )
        _model = State(initialValue: model)
#if canImport(BackgroundTasks) && os(iOS)
        FeedDemoBackgroundProcessingBridge.shared.install(model)
        model.recordBackgroundRegistration(.refresh, accepted: true)
#endif
    }

    var body: some Scene {
        WindowGroup {
            FeedDemoRootView(model: model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleApplicationPhase(FeedDemoApplicationPhase(phase))
        }
#if canImport(BackgroundTasks) && os(iOS)
        .backgroundTask(.appRefresh(FeedDemoBackgroundTaskIdentifiers.refresh)) {
            _ = await model.performBackgroundTask(.refresh)
        }
#endif
    }
}

private extension FeedDemoApplicationPhase {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active:
            self = .active
        case .inactive:
            self = .inactive
        case .background:
            self = .background
        @unknown default:
            self = .inactive
        }
    }
}

#if canImport(BackgroundTasks) && os(iOS)
@MainActor
final class FeedDemoBackgroundProcessingBridge {
    static let shared = FeedDemoBackgroundProcessingBridge()

    private weak var model: FeedDemoModel?
    private var registrationResult: Bool?

    private init() {}

    func install(_ model: FeedDemoModel) {
        self.model = model
        if let registrationResult {
            model.recordBackgroundRegistration(.processing, accepted: registrationResult)
        }
    }

    func recordRegistration(_ accepted: Bool) {
        registrationResult = accepted
        model?.recordBackgroundRegistration(.processing, accepted: accepted)
    }

    func launch(_ task: BGTask) {
        guard let model else {
            task.expirationHandler = {}
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak model] in
            Task { @MainActor in
                model?.expireBackgroundTask(.processing)
            }
        }
        Task { @MainActor [weak model, weak task] in
            guard let model, let task else { return }
            let success = await model.performBackgroundTask(.processing)
            task.setTaskCompleted(success: success)
        }
    }
}

@MainActor
final class FeedDemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = application
        _ = launchOptions
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: FeedDemoBackgroundTaskIdentifiers.processing,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                FeedDemoBackgroundProcessingBridge.shared.launch(task)
            }
        }
        FeedDemoBackgroundProcessingBridge.shared.recordRegistration(accepted)
        return true
    }
}
#endif
