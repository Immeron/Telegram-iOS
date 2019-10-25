import Foundation
import UIKit
import Postbox
import Display
import SwiftSignalKit
import MonotonicTime
import AccountContext
import TelegramPresentationData
import PasscodeUI
import TelegramUIPreferences
import ImageBlur
import AppLockState

private func isLocked(passcodeSettings: PresentationPasscodeSettings, state: LockState, isApplicationActive: Bool) -> Bool {
    if state.isManuallyLocked {
        return true
    } else if let autolockTimeout = passcodeSettings.autolockTimeout {
        var bootTimestamp: Int32 = 0
        let uptime = getDeviceUptimeSeconds(&bootTimestamp)
        let timestamp = MonotonicTimestamp(bootTimestap: bootTimestamp, uptime: uptime)
        
        let applicationActivityTimestamp = state.applicationActivityTimestamp
        
        if let applicationActivityTimestamp = applicationActivityTimestamp {
            if timestamp.bootTimestap != applicationActivityTimestamp.bootTimestap {
                return true
            }
            if timestamp.uptime >= applicationActivityTimestamp.uptime + autolockTimeout {
                return true
            }
        } else {
            return true
        }
    }
    return false
}

private func getCoveringViewSnaphot(window: Window1) -> UIImage? {
    let scale: CGFloat = 0.5
    let unscaledSize = window.hostView.containerView.frame.size
    return generateImage(CGSize(width: floor(unscaledSize.width * scale), height: floor(unscaledSize.height * scale)), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.scaleBy(x: scale, y: scale)
        UIGraphicsPushContext(context)
        window.hostView.containerView.drawHierarchy(in: CGRect(origin: CGPoint(), size: unscaledSize), afterScreenUpdates: false)
        UIGraphicsPopContext()
    }).flatMap(applyScreenshotEffectToImage)
}

public final class AppLockContextImpl: AppLockContext {
    private let rootPath: String
    private let syncQueue = Queue()
    
    private let applicationBindings: TelegramApplicationBindings
    private let accountManager: AccountManager
    private let presentationDataSignal: Signal<PresentationData, NoError>
    private let window: Window1?
    
    private var coveringView: LockedWindowCoveringView?
    private var passcodeController: PasscodeEntryController?
    
    private var timestampRenewTimer: SwiftSignalKit.Timer?
    
    private var currentStateValue: LockState
    private let currentState = Promise<LockState>()
    
    public init(rootPath: String, window: Window1?, applicationBindings: TelegramApplicationBindings, accountManager: AccountManager, presentationDataSignal: Signal<PresentationData, NoError>, lockIconInitialFrame: @escaping () -> CGRect?) {
        assert(Queue.mainQueue().isCurrent())
        
        self.applicationBindings = applicationBindings
        self.accountManager = accountManager
        self.presentationDataSignal = presentationDataSignal
        self.rootPath = rootPath
        self.window = window
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: appLockStatePath(rootPath: self.rootPath))), let current = try? JSONDecoder().decode(LockState.self, from: data) {
            self.currentStateValue = current
        } else {
            self.currentStateValue = LockState()
        }
        
        let _ = (combineLatest(queue: .mainQueue(),
            accountManager.accessChallengeData(),
            accountManager.sharedData(keys: Set([ApplicationSpecificSharedDataKeys.presentationPasscodeSettings])),
            presentationDataSignal,
            applicationBindings.applicationIsActive,
            self.currentState.get()
        )
        |> deliverOnMainQueue).start(next: { [weak self] accessChallengeData, sharedData, presentationData, appInForeground, state in
            guard let strongSelf = self else {
                return
            }
            
            let passcodeSettings: PresentationPasscodeSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationPasscodeSettings] as? PresentationPasscodeSettings ?? .defaultSettings
            
            var shouldDisplayCoveringView = false
            
            if !accessChallengeData.data.isLockable {
                if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    passcodeController.dismiss()
                }
            } else {
                if let autolockTimeout = passcodeSettings.autolockTimeout, !appInForeground {
                    shouldDisplayCoveringView = true
                }
                
                if isLocked(passcodeSettings: passcodeSettings, state: state, isApplicationActive: appInForeground) {
                    if strongSelf.passcodeController == nil {
                        let biometrics: PasscodeEntryControllerBiometricsMode
                        if passcodeSettings.enableBiometrics {
                            biometrics = .enabled(passcodeSettings.biometricsDomainState)
                        } else {
                            biometrics = .none
                        }
                        
                        let passcodeController = PasscodeEntryController(applicationBindings: strongSelf.applicationBindings, accountManager: strongSelf.accountManager, appLockContext: strongSelf, presentationData: presentationData, presentationDataSignal: strongSelf.presentationDataSignal, challengeData: accessChallengeData.data, biometrics: biometrics, arguments: PasscodeEntryControllerPresentationArguments(animated: true, lockIconInitialFrame: { [weak self] in
                            if let lockViewFrame = lockIconInitialFrame() {
                                return lockViewFrame
                            } else {
                                return CGRect()
                            }
                        }))
                        passcodeController.presentedOverCoveringView = true
                        strongSelf.passcodeController = passcodeController
                        strongSelf.window?.present(passcodeController, on: .passcode)
                    }
                } else if let passcodeController = strongSelf.passcodeController {
                    strongSelf.passcodeController = nil
                    passcodeController.dismiss()
                }
            }
            
            strongSelf.updateTimestampRenewTimer(shouldRun: appInForeground && accessChallengeData.data.isLockable)
            
            if shouldDisplayCoveringView {
                if strongSelf.coveringView == nil, let window = strongSelf.window {
                    let coveringView = LockedWindowCoveringView(theme: presentationData.theme)
                    coveringView.updateSnapshot(getCoveringViewSnaphot(window: window))
                    strongSelf.coveringView = coveringView
                    window.coveringView = coveringView
                }
            } else {
                if let coveringView = strongSelf.coveringView {
                    strongSelf.coveringView = nil
                    strongSelf.window?.coveringView = nil
                }
            }
        })
        
        self.currentState.set(.single(self.currentStateValue))
    }
    
    private func updateTimestampRenewTimer(shouldRun: Bool) {
        if shouldRun {
            if self.timestampRenewTimer == nil {
                let timestampRenewTimer = SwiftSignalKit.Timer(timeout: 5.0, repeat: true, completion: { [weak self] in
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateApplicationActivityTimestamp()
                }, queue: .mainQueue())
                self.timestampRenewTimer = timestampRenewTimer
                timestampRenewTimer.start()
            }
        } else {
            if let timestampRenewTimer = self.timestampRenewTimer {
                self.timestampRenewTimer = nil
                timestampRenewTimer.invalidate()
            }
        }
    }
    
    private func updateApplicationActivityTimestamp() {
        self.updateLockState { state in
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            
            var state = state
            state.applicationActivityTimestamp = MonotonicTimestamp(bootTimestap: bootTimestamp, uptime: uptime)
            return state
        }
    }
    
    private func updateLockState(_ f: @escaping (LockState) -> LockState) {
        Queue.mainQueue().async {
            let updatedState = f(self.currentStateValue)
            if updatedState != self.currentStateValue {
                self.currentStateValue = updatedState
                self.currentState.set(.single(updatedState))
                
                let path = appLockStatePath(rootPath: self.rootPath)
                
                self.syncQueue.async {
                    if let data = try? JSONEncoder().encode(updatedState) {
                        let _ = try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                    }
                }
            }
        }
    }
    
    public var invalidAttempts: Signal<AccessChallengeAttempts?, NoError> {
        return self.currentState.get()
        |> map { state in
            return state.unlockAttemts.flatMap { unlockAttemts in
                return AccessChallengeAttempts(count: unlockAttemts.count, timestamp: unlockAttemts.wallClockTimestamp)
            }
        }
    }
    
    public func lock() {
        self.updateLockState { state in
            var state = state
            state.isManuallyLocked = true
            return state
        }
    }
    
    public func unlock() {
        self.updateLockState { state in
            var state = state
            
            state.unlockAttemts = nil
            
            state.isManuallyLocked = false
            
            var bootTimestamp: Int32 = 0
            let uptime = getDeviceUptimeSeconds(&bootTimestamp)
            let timestamp = MonotonicTimestamp(bootTimestap: bootTimestamp, uptime: uptime)
            state.applicationActivityTimestamp = timestamp
            
            return state
        }
    }
    
    public func failedUnlockAttempt() {
        self.updateLockState { state in
            var state = state
            var unlockAttemts = state.unlockAttemts ?? UnlockAttempts(count: 0, wallClockTimestamp: 0)
            unlockAttemts.count += 1
            unlockAttemts.wallClockTimestamp = Int32(CFAbsoluteTimeGetCurrent())
            state.unlockAttemts = unlockAttemts
            return state
        }
    }
}