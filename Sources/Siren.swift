//
//  Siren.swift
//  Siren
//
//  Created by Arthur Sabintsev on 1/3/15.
//  Copyright (c) 2015 Sabintsev iOS Projects. All rights reserved.
//

import UIKit

/// The Siren Class. A singleton that is initialized using the `shared` constant.
public final class Siren: NSObject {
    /// Return results or errors obtained from performing a version check with Siren.
    public typealias ResultsHandler = (Results?, KnownError?) -> Void

    /// The Siren singleton. The main point of entry to the Siren library.
    public static let shared = Siren()

    /// The manager that controls the update alert's localization and tint color.
    ///
    /// Defaults to the user's device localization.
    public lazy var presentationManager: PresentationManager = .default

    /// The manager that controls the App Store API that is
    /// used to fetch the latest version of the app.
    ///
    /// Defaults to the US App Store.
    public lazy var apiManager: APIManager = .default

    /// The manager that controls the type of alert that should be displayed
    /// and how often an alert should be displayed dpeneding on the type
    /// of update that is available relative to the installed version of the app
    /// (e.g., different rules for major, minor, patch and revision updated can be used).
    ///
    /// Default to performing a version check once a day, but allows the user
    /// to skip updating the app until the next time the app becomes active or
    /// skipping the update all together until another version is released.
    public lazy var rulesManager: RulesManager = .default

    /// The debug flag, which is disabled by default.
    /// When enabled, a stream of `print()` statements are logged to your console when a version check is performed.
    public lazy var debugEnabled: Bool = false

    /// The current installed version of your app.
    internal lazy var currentInstalledVersion: String? = Bundle.version()

    /// The current version of your app that is available for download on the App Store
    internal var currentAppStoreVersion: String?

    /// The retained `NotificationCenter` observer that listens for `UIApplication.didBecomeActiveNotification` notifications.
    internal var didBecomeActiveObserver: NSObjectProtocol?

    /// The completion handler used to return the results or errors returned by Siren.
    private var resultsHandler: ResultsHandler?

    /// The Swift model representation of API results from the iTunes Lookup API.
    private var lookupModel: LookupModel?

    /// The instance of the `UIAlertController` used to present the update alert.
    private var alertController: UIAlertController?

    /// The last date that an alert was presented to the user.
    private var alertPresentationDate: Date?

    /// The App Store's unique identifier for an app.
    private var appID: Int?

    /// The type of update that is available on the App Store.
    ///
    /// Defaults to `unknown` until a version check is successfully performed.
    private lazy var updateType: RulesManager.UpdateType = .unknown

    /// Tracks the current presentation state of the update alert.
    ///
    /// `true` if the alert view is currently being presented to the user. Otherwise, `false`.
    private lazy var alertViewIsVisible: Bool = false

    /// The `UIWindow` instance that presents the `SirenViewController`.
    private var updaterWindow: UIWindow {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = SirenViewController()
        window.windowLevel = UIWindow.Level.alert + 1
        return window
    }

    /// The initialization method.
    private override init() {
        alertPresentationDate = UserDefaults.alertPresentationDate
    }
}

// MARK: - Public Functionality

public extension Siren {
    ///
    ///
    /// - Parameter handler:
    func wail(completion handler: ResultsHandler?) {
        resultsHandler = handler
        addObservers()
    }

    /// Launches the AppStore in two situations:
    ///
    /// - User clicked the `Update` button in the UIAlertController modal.
    /// - Developer built a custom alert modal and needs to be able to call this function when the user chooses to update the app in the aforementioned custom modal.
    func launchAppStore() {
        guard let appID = appID,
            let url = URL(string: "https://itunes.apple.com/app/id\(appID)") else {
                resultsHandler?(nil, .malformedURL)
                return
        }

        DispatchQueue.main.async {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
        }
    }
}

// MARK: - Networking

extension Siren {
    func performVersionCheck() {
        updateType = .unknown
        apiManager.performVersionCheckRequest { [weak self] (lookupModel, error) in
            guard let self = self else { return }
            guard let lookupModel = lookupModel, error == nil else {
                self.resultsHandler?(nil, error)
                return
            }

            self.analyze(model: lookupModel)
        }
    }

    private func analyze(model: LookupModel) {
        // Check if the latest version is compatible with current device's version of iOS.
        guard isUpdateCompatibleWithDeviceOS(for: model) else {
            resultsHandler?(nil, .appStoreOSVersionUnsupported)
            return
        }

        // Check and store the App ID .
        guard let appID = model.results.first?.appID else {
            resultsHandler?(nil, .appStoreAppIDFailure)
            return
        }
        self.appID = appID

        // Check and store the current App Store version.
        guard let currentAppStoreVersion = model.results.first?.version else {
            resultsHandler?(nil, .appStoreVersionArrayFailure)
            return
        }
        self.currentAppStoreVersion = currentAppStoreVersion

        // Check if the App Store version is newer than the currently installed version.
        guard VersionParser.isAppStoreVersionNewer(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion) else {
            resultsHandler?(nil, .noUpdateAvailable)
            return
        }

        // Check the release date of the current version.
        guard let currentVersionReleaseDate = model.results.first?.currentVersionReleaseDate,
            let daysSinceRelease = Date.days(since: currentVersionReleaseDate) else {
                resultsHandler?(nil, .currentVersionReleaseDate)
                return
        }

        // Check if applicaiton has been released for the amount of days defined by the app consuming Siren.
        guard daysSinceRelease >= rulesManager.releasedForDays else {
            resultsHandler?(nil, .releasedTooSoon(daysSinceRelease: daysSinceRelease,
                                                     releasedForDays: rulesManager.releasedForDays))
            return
        }

        determineIfAlertPresentationRulesAreSatisfied()
    }
}

// MARK: - Alert Presentation

private extension Siren {
    func determineIfAlertPresentationRulesAreSatisfied() {
        // Determine the set of alert presentation rules based on the type of version update.
        updateType = VersionParser.parse(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion)
        let rules = rulesManager.loadRulesForUpdateType(updateType)

        // Did the user:
        // - request to skip being prompted with version update alerts for a specific version
        // - and is the latest App Store update the same version that was requested?
        if let previouslySkippedVersion = UserDefaults.storedSkippedVersion,
            let currentInstalledVersion = currentInstalledVersion,
            let currentAppStoreVersion = currentAppStoreVersion,
            currentAppStoreVersion != previouslySkippedVersion {
            resultsHandler?(nil, .skipVersionUpdate(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion))
                return
        }

        if rules.frequency == .immediately {
            showAlert(withRules: rules)
        } else if UserDefaults.shouldPerformVersionCheckOnSubsequentLaunch {
            UserDefaults.shouldPerformVersionCheckOnSubsequentLaunch = false
            showAlert(withRules: rules)
        } else {
            guard let alertPresentationDate = alertPresentationDate else {
                showAlert(withRules: rules)
                return
            }

            if Date.days(since: alertPresentationDate) >= rules.frequency.rawValue {
                showAlert(withRules: rules)
            } else {
                resultsHandler?(nil, .recentlyCheckedVersion)
            }
        }
    }

    func showAlert(withRules rules: Rules) {
        UserDefaults.alertPresentationDate = Date()

        let localization = Localization(presentationManager: presentationManager, forCurrentAppStoreVersion: currentAppStoreVersion)
        let alertTitle = localization.alertTitle()
        let alertMessage = localization.alertMessage()

       alertController = UIAlertController(title: alertTitle,
                                           message: alertMessage,
                                           preferredStyle: .alert)

        if let alertControllerTintColor = presentationManager.tintColor {
            alertController?.view.tintColor = alertControllerTintColor
        }

        switch rules.alertType {
        case .force:
            alertController?.addAction(updateAlertAction())
        case .option:
            alertController?.addAction(nextTimeAlertAction())
            alertController?.addAction(updateAlertAction())
        case .skip:
            alertController?.addAction(nextTimeAlertAction())
            alertController?.addAction(updateAlertAction())
            alertController?.addAction(skipAlertAction())
        case .none:
            let results = Results(alertAction: .unknown,
                                  localization: localization,
                                  lookupModel: lookupModel,
                                  updateType: updateType)
            resultsHandler?(results, nil)
        }

        if rules.alertType != .none && !alertViewIsVisible {
            alertController?.show(window: updaterWindow)
            alertViewIsVisible = true
        }
    }

    func updateAlertAction() -> UIAlertAction {
        let localization = Localization(presentationManager: presentationManager, forCurrentAppStoreVersion: currentAppStoreVersion)
        let action = UIAlertAction(title: localization.updateButtonTitle(), style: .default) { [weak self] _ in
            guard let self = self else { return }

            self.alertController?.hide(window: self.updaterWindow)
            self.launchAppStore()
            self.alertViewIsVisible = false

            let results = Results(alertAction: .appStore,
                                  localization: localization,
                                  lookupModel: self.lookupModel,
                                  updateType: self.updateType)
            self.resultsHandler?(results, nil)
            return
        }

        return action
    }

    func nextTimeAlertAction() -> UIAlertAction {
        let localization = Localization(presentationManager: presentationManager, forCurrentAppStoreVersion: currentAppStoreVersion)
        let action = UIAlertAction(title: localization.nextTimeButtonTitle(), style: .default) { [weak self] _  in
            guard let self = self else { return }

            self.alertController?.hide(window: self.updaterWindow)
            self.alertViewIsVisible = false
            UserDefaults.shouldPerformVersionCheckOnSubsequentLaunch = true

            let results = Results(alertAction: .nextTime,
                                  localization: localization,
                                  lookupModel: self.lookupModel,
                                  updateType: self.updateType)
            self.resultsHandler?(results, nil)
            return
        }

        return action
    }

    func skipAlertAction() -> UIAlertAction {
        let localization = Localization(presentationManager: presentationManager, forCurrentAppStoreVersion: currentAppStoreVersion)
        let action = UIAlertAction(title: localization.skipButtonTitle(), style: .default) { [weak self] _ in
            guard let self = self else { return }

            if let currentAppStoreVersion = self.currentAppStoreVersion {
                UserDefaults.storedSkippedVersion = currentAppStoreVersion
                UserDefaults.standard.synchronize()
            }

            self.alertController?.hide(window: self.updaterWindow)
            self.alertViewIsVisible = false

            let results = Results(alertAction: .skip,
                                  localization: localization,
                                  lookupModel: self.lookupModel,
                                  updateType: self.updateType)
            self.resultsHandler?(results, nil)
            return
        }

        return action
    }
}

// MARK: - Helpers

private extension Siren {
    func addObservers() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter
            .default
            .addObserver(forName: UIApplication.didBecomeActiveNotification,
                         object: nil,
                         queue: nil) { [weak self] _ in
                            guard let self = self else { return }
                            self.performVersionCheck()
        }
    }

    func isUpdateCompatibleWithDeviceOS(for model: LookupModel) -> Bool {
        guard let requiredOSVersion = model.results.first?.minimumOSVersion else {
            return false
        }

        let systemVersion = UIDevice.current.systemVersion

        guard systemVersion.compare(requiredOSVersion, options: .numeric) == .orderedDescending ||
            systemVersion.compare(requiredOSVersion, options: .numeric) == .orderedSame else {
                return false
        }

        return true
    }
}
