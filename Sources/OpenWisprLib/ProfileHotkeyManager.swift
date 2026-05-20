import AppKit
import Foundation

final class ProfileHotkeyManager {
    private static let modifierMask: UInt64 = 0x00FE0000
    private static let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    private static let deferredStartDelay: TimeInterval = 0.25

    private var globalMonitor: Any?
    private let profiles: [DictationProfile]
    private let toggleMode: Bool
    private var onKeyDown: ((DictationProfile) -> Void)?
    private var onKeyUp: ((DictationProfile) -> Void)?
    private var activeProfile: DictationProfile?
    private var pendingProfile: DictationProfile?
    private var pendingWorkItem: DispatchWorkItem?
    private var pressedModifierKeys: Set<UInt16> = []

    init(profiles: [DictationProfile], toggleMode: Bool = false) {
        self.profiles = profiles
        self.toggleMode = toggleMode
    }

    func start(
        onKeyDown: @escaping (DictationProfile) -> Void,
        onKeyUp: @escaping (DictationProfile) -> Void
    ) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        cancelPendingStart()
        activeProfile = nil
    }

    private func handleEvent(_ event: NSEvent) {
        if event.type == .flagsChanged, Self.isModifierOnlyKey(event.keyCode) {
            if updateModifierState(event) {
                handlePress(event)
            } else {
                handleRelease(event)
            }
            return
        }

        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            handlePress(event)
        case .keyUp:
            handleRelease(event)
        default:
            break
        }
    }

    private func handlePress(_ event: NSEvent) {
        if !toggleMode, let activeProfile = activeProfile {
            if shouldRelease(activeProfile, event: event) {
                finish(activeProfile)
            }
            return
        }

        guard let candidate = matchingProfile(for: event) else { return }

        if pendingProfile != nil {
            cancelPendingStart()
        }

        if shouldDefer(candidate) {
            schedulePendingStart(candidate)
        } else {
            begin(candidate)
        }
    }

    private func handleRelease(_ event: NSEvent) {
        if let pendingProfile = pendingProfile, shouldRelease(pendingProfile, event: event) {
            cancelPendingStart()
            if toggleMode {
                begin(pendingProfile)
            }
            return
        }

        if toggleMode {
            return
        }

        guard let activeProfile = activeProfile else { return }
        if shouldRelease(activeProfile, event: event) {
            finish(activeProfile)
        }
    }

    private func begin(_ profile: DictationProfile) {
        if !toggleMode {
            activeProfile = profile
        }
        onKeyDown?(profile)
    }

    private func finish(_ profile: DictationProfile) {
        activeProfile = nil
        onKeyUp?(profile)
    }

    private func schedulePendingStart(_ profile: DictationProfile) {
        pendingProfile = profile
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.pendingProfile?.id == profile.id else { return }
            self.pendingProfile = nil
            self.pendingWorkItem = nil
            self.begin(profile)
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deferredStartDelay, execute: workItem)
    }

    private func cancelPendingStart() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingProfile = nil
    }

    private func matchingProfile(for event: NSEvent) -> DictationProfile? {
        let candidates = profiles.filter { matches($0.hotkey, event: event) }
        return candidates.sorted { lhs, rhs in
            let lhsScore = specificityScore(lhs.hotkey)
            let rhsScore = specificityScore(rhs.hotkey)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.id < rhs.id
        }.first
    }

    private func matches(_ hotkey: HotkeyConfig, event: NSEvent) -> Bool {
        if Self.isModifierOnlyKey(hotkey.keyCode) {
            let current = currentModifiers(event)
            guard let ownFlag = Self.ownModifierFlag(for: hotkey.keyCode) else { return false }
            guard current & ownFlag == ownFlag else { return false }
            return (current & ~ownFlag) == hotkey.modifierFlags
        }

        guard event.type == .keyDown else { return false }
        guard event.keyCode == hotkey.keyCode else { return false }
        return currentModifiers(event) == hotkey.modifierFlags
    }

    private func shouldRelease(_ profile: DictationProfile, event: NSEvent) -> Bool {
        let hotkey = profile.hotkey
        if Self.isModifierOnlyKey(hotkey.keyCode) {
            guard event.type == .flagsChanged else { return false }
            guard event.keyCode == hotkey.keyCode else { return false }
            guard let ownFlag = Self.ownModifierFlag(for: hotkey.keyCode) else { return false }
            return currentModifiers(event) & ownFlag == 0
        }

        return event.type == .keyUp && event.keyCode == hotkey.keyCode
    }

    private func shouldDefer(_ profile: DictationProfile) -> Bool {
        let hotkey = profile.hotkey
        guard Self.isModifierOnlyKey(hotkey.keyCode), hotkey.modifierFlags == 0 else { return false }
        guard let ownFlag = Self.ownModifierFlag(for: hotkey.keyCode) else { return false }
        return profiles.contains { other in
            guard other.hotkey != hotkey else { return false }
            return other.hotkey.modifierFlags & ownFlag == ownFlag
                || other.hotkey.keyCode == hotkey.keyCode
        }
    }

    private func specificityScore(_ hotkey: HotkeyConfig) -> Int {
        hotkey.modifiers.count + (Self.isModifierOnlyKey(hotkey.keyCode) ? 0 : 1)
    }

    private func currentModifiers(_ event: NSEvent) -> UInt64 {
        var flags = UInt64(event.modifierFlags.rawValue) & Self.modifierMask
        for keyCode in pressedModifierKeys {
            if let flag = Self.ownModifierFlag(for: keyCode) {
                flags |= flag
            }
        }
        return flags
    }

    private func updateModifierState(_ event: NSEvent) -> Bool {
        guard let ownFlag = Self.ownModifierFlag(for: event.keyCode) else { return false }
        let rawFlags = UInt64(event.modifierFlags.rawValue) & Self.modifierMask
        let rawSaysDown = rawFlags & ownFlag == ownFlag
        let wasDown = pressedModifierKeys.contains(event.keyCode)

        let isDown: Bool
        if rawSaysDown {
            isDown = true
        } else if wasDown {
            isDown = false
        } else {
            isDown = true
        }

        if isDown {
            pressedModifierKeys.insert(event.keyCode)
        } else {
            pressedModifierKeys.remove(event.keyCode)
        }

        return isDown
    }

    private static func isModifierOnlyKey(_ code: UInt16) -> Bool {
        modifierOnlyKeyCodes.contains(code)
    }

    private static func ownModifierFlag(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 54, 55:
            return UInt64(1 << 20)
        case 56, 60:
            return UInt64(1 << 17)
        case 58, 61:
            return UInt64(1 << 19)
        case 59, 62:
            return UInt64(1 << 18)
        case 63:
            return UInt64(1 << 23)
        default:
            return nil
        }
    }
}
