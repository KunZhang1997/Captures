import AppKit
import Carbon.HIToolbox
import OSLog

final class HotkeyManager {
    private static let logger = Logger(subsystem: "com.captures.app", category: "Hotkeys")
    private(set) static var isPriorityHotkeyActive = false

    private let appState: AppState
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retapTimer: Timer?
    private var permissionRetryTimer: Timer?
    private var carbonRetryTimer: Timer?
    private var carbonHandlerRef: EventHandlerRef?
    private var carbonHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var carbonHotkeyActionsByID: [UInt32: HotkeyAction] = [:]
    private var carbonRegistrationFailures: [HotkeyAction: OSStatus] = [:]
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var bindingsObserver: NSObjectProtocol?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var hasLoggedMissingPermission = false
    private var hasShownEventTapFailurePrompt = false
    private var permissionRetryCount = 0
    private let maxPermissionRetries = 40
    private let carbonSignature = OSType(0x534E5052) // "SNPR"

    /// Current user bindings, kept in sync with AppState.
    private var bindings: [HotkeyAction: HotkeyBinding] = [:]
    /// Guards against the same physical key press being delivered through two
    /// paths at once (event tap + Carbon, or Carbon + NSEvent fallback).
    private var lastDispatched: (action: HotkeyAction, at: Date)?
    private var lastReportedConflictActions: Set<HotkeyAction> = []

    var hasActiveGlobalHotkeys: Bool {
        hasPriorityGlobalHotkeys || !carbonHotKeyRefs.isEmpty
    }

    var hasPriorityGlobalHotkeys: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(appState: AppState) {
        self.appState = appState
        self.bindings = appState.hotkeyBindings
        bindingsObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyBindingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadBindings()
        }
        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.retryFailedCarbonHotkeys()
        }
    }

    deinit {
        if let bindingsObserver {
            NotificationCenter.default.removeObserver(bindingsObserver)
        }
        if let workspaceTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceTerminationObserver)
        }
        stop()
    }

    func start() {
        bindings = appState.hotkeyBindings
        installCarbonHotkeysIfNeeded()
        installEventTapIfAllowed()
        if !hasPriorityGlobalHotkeys {
            installFallbackMonitorsIfNeeded()
        } else {
            removeFallbackMonitors()
        }
        reportShortcutConflictsIfNeeded()
        startPermissionRetry()
    }

    func stop() {
        retapTimer?.invalidate()
        retapTimer = nil
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        carbonRetryTimer?.invalidate()
        carbonRetryTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        publishPriorityStatus(false)
        removeFallbackMonitors()
        unregisterCarbonHotkeys()
    }

    private func reloadBindings() {
        bindings = appState.hotkeyBindings
        if carbonHandlerRef != nil {
            unregisterCarbonHotkeyRefs()
            registerCarbonHotkeys()
        }
        startCarbonRetryIfNeeded()
        reportShortcutConflictsIfNeeded()
    }

    // MARK: - Matching & dispatch

    private func action(forKeyCode keyCode: Int, flags: CGEventFlags) -> HotkeyAction? {
        bindings.first(where: { $0.value.matches(keyCode: keyCode, flags: flags) })?.key
    }

    fileprivate func dispatch(_ action: HotkeyAction) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastDispatched,
               last.action == action,
               now.timeIntervalSince(last.at) < 0.25 {
                return
            }
            self.lastDispatched = (action, now)
            Self.logger.notice("Dispatching hotkey action \(action.rawValue, privacy: .public)")

            switch action {
            case .toggleDesktopIcons:
                DesktopIconsHelper.toggle()
            default:
                if let mode = action.captureMode {
                    NotificationCenter.default.post(name: .startCapture, object: mode)
                }
            }
        }
    }

    // MARK: - CGEvent tap (primary path; can suppress system shortcuts)

    private func startPermissionRetry() {
        guard permissionRetryTimer == nil, eventTap == nil else { return }
        permissionRetryCount = 0
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.permissionRetryCount += 1
            if self.permissionRetryCount >= self.maxPermissionRetries {
                timer.invalidate()
                self.permissionRetryTimer = nil
                return
            }
            self.installEventTapIfAllowed()
        }
    }

    private func installEventTapIfAllowed() {
        guard eventTap == nil else { return }
        let accessibilityGranted = PermissionChecker.isAccessibilityGranted()
        guard accessibilityGranted else {
            if !hasLoggedMissingPermission {
                print("Accessibility permission not granted, priority hotkeys unavailable")
                Self.logger.notice("Using permission-free Carbon hotkeys; Accessibility interception is optional")
                hasLoggedMissingPermission = true
            }
            publishPriorityStatus(false)
            return
        }

        hasLoggedMissingPermission = false
        Self.logger.notice("Priority hotkey install requested with Accessibility access")
        installEventTap()
        if hasPriorityGlobalHotkeys {
            removeFallbackMonitors()
            permissionRetryTimer?.invalidate()
            permissionRetryTimer = nil
            startHealthCheck()
            lastReportedConflictActions.removeAll()
        }
    }

    private func installEventTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        )

        guard let tap = eventTap else {
            print("Failed to create CGEvent tap")
            Self.logger.error("CGEvent tap creation failed despite Accessibility access")
            publishPriorityStatus(false)
            if !hasShownEventTapFailurePrompt {
                hasShownEventTapFailurePrompt = true
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = Localization.string("Priority Hotkeys Could Not Start")
                    alert.informativeText = Localization.string("Captures has Accessibility access, but couldn't activate priority shortcut interception. Quit and reopen Captures, then try again.")
                    alert.addButton(withTitle: Localization.string("Open Settings"))
                    alert.addButton(withTitle: Localization.string("Cancel"))
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        PermissionChecker.openAccessibilitySettings()
                    }
                }
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        Self.logger.notice("CGEvent tap created; enabled=\(enabled, privacy: .public)")
        publishPriorityStatus(enabled)
    }

    private func startHealthCheck() {
        retapTimer?.invalidate()
        retapTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            self.publishPriorityStatus(CGEvent.tapIsEnabled(tap: tap))
        }
    }

    fileprivate func reenableEventTapAfterDisable() {
        guard let eventTap else {
            publishPriorityStatus(false)
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: eventTap)
        Self.logger.warning("CGEvent tap was disabled and re-enabled; enabled=\(enabled, privacy: .public)")
        publishPriorityStatus(enabled)
    }

    private func publishPriorityStatus(_ isActive: Bool) {
        guard Self.isPriorityHotkeyActive != isActive else { return }
        Self.isPriorityHotkeyActive = isActive
        NotificationCenter.default.post(name: .priorityHotkeyStatusChanged, object: isActive)
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> CGEvent? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let action = action(forKeyCode: keyCode, flags: event.flags) else {
            return event
        }
        Self.logger.notice("Received \(action.rawValue, privacy: .public) through active event tap")
        dispatch(action)
        // Suppress the event so a colliding system shortcut (e.g. ⌘⇧3)
        // doesn't also fire.
        return nil
    }

    // MARK: - Carbon hotkeys (backup path)

    private func installCarbonHotkeysIfNeeded() {
        guard carbonHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonHotkeyCallback,
            1,
            &eventType,
            selfPtr,
            &carbonHandlerRef
        )

        guard installStatus == noErr else {
            print("Failed to install Carbon hotkey handler: \(installStatus)")
            carbonHandlerRef = nil
            return
        }

        registerCarbonHotkeys()
    }

    private func registerCarbonHotkeys() {
        carbonRegistrationFailures.removeAll()
        for (action, binding) in bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            registerCarbonHotkey(action: action, binding: binding)
        }
        startCarbonRetryIfNeeded()
    }

    private func registerCarbonHotkey(action: HotkeyAction, binding: HotkeyBinding) {
        let id = carbonID(for: action)
        guard carbonHotKeyRefs[id] == nil else {
            carbonRegistrationFailures.removeValue(forKey: action)
            return
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: carbonSignature, id: id)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            carbonModifiers(from: binding.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            carbonHotKeyRefs[id] = hotKeyRef
            carbonHotkeyActionsByID[id] = action
            carbonRegistrationFailures.removeValue(forKey: action)
            Self.logger.notice("Registered permission-free hotkey for \(action.rawValue, privacy: .public)")
        } else {
            carbonRegistrationFailures[action] = status
            Self.logger.notice("Permission-free hotkey is occupied for \(action.rawValue, privacy: .public); status=\(status, privacy: .public)")
        }
    }

    private func carbonID(for action: HotkeyAction) -> UInt32 {
        let orderedActions = HotkeyAction.allCases.sorted { $0.rawValue < $1.rawValue }
        return UInt32((orderedActions.firstIndex(of: action) ?? 0) + 1)
    }

    private func startCarbonRetryIfNeeded() {
        guard !carbonRegistrationFailures.isEmpty else {
            carbonRetryTimer?.invalidate()
            carbonRetryTimer = nil
            return
        }
        guard carbonRetryTimer == nil else { return }
        carbonRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.retryFailedCarbonHotkeys()
        }
    }

    private func retryFailedCarbonHotkeys() {
        guard carbonHandlerRef != nil else { return }
        let failedActions = carbonRegistrationFailures.keys.sorted { $0.rawValue < $1.rawValue }
        guard !failedActions.isEmpty else {
            startCarbonRetryIfNeeded()
            return
        }
        for action in failedActions {
            guard let binding = bindings[action] else {
                carbonRegistrationFailures.removeValue(forKey: action)
                continue
            }
            registerCarbonHotkey(action: action, binding: binding)
        }
        startCarbonRetryIfNeeded()
        reportShortcutConflictsIfNeeded()
    }

    private func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private func unregisterCarbonHotkeyRefs() {
        for (_, hotKeyRef) in carbonHotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        carbonHotKeyRefs.removeAll()
        carbonHotkeyActionsByID.removeAll()
        carbonRegistrationFailures.removeAll()
    }

    private func unregisterCarbonHotkeys() {
        unregisterCarbonHotkeyRefs()

        if let carbonHandlerRef {
            RemoveEventHandler(carbonHandlerRef)
            self.carbonHandlerRef = nil
        }
    }

    fileprivate func handleCarbonHotkeyEvent(_ event: EventRef?) {
        // Event tap has priority because it can suppress system screenshots.
        if hasPriorityGlobalHotkeys {
            return
        }

        guard let event else { return }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == carbonSignature else { return }
        guard let action = carbonHotkeyActionsByID[hotKeyID.id] else { return }
        Self.logger.notice("Received \(action.rawValue, privacy: .public) through Carbon hotkey")
        dispatch(action)
    }

    // MARK: - NSEvent fallback (no Accessibility permission)

    private func installFallbackMonitorsIfNeeded() {
        if fallbackGlobalMonitor == nil {
            fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleFallbackHotkey(event)
            }
        }
        if fallbackLocalMonitor == nil {
            fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleFallbackHotkey(event)
                return event
            }
        }
    }

    private func removeFallbackMonitors() {
        if let fallbackGlobalMonitor {
            NSEvent.removeMonitor(fallbackGlobalMonitor)
            self.fallbackGlobalMonitor = nil
        }
        if let fallbackLocalMonitor {
            NSEvent.removeMonitor(fallbackLocalMonitor)
            self.fallbackLocalMonitor = nil
        }
    }

    private func handleFallbackHotkey(_ event: NSEvent) {
        // Event tap has priority because it can suppress system screenshots.
        if hasPriorityGlobalHotkeys {
            return
        }

        // Handle every binding here rather than deferring to Carbon: the
        // system-reserved screenshot shortcuts (⌘⇧3/⌘⇧4) never reach
        // RegisterEventHotKey handlers, and dispatch() dedups the rest.
        let flags = cgEventFlags(from: event.modifierFlags)
        guard let action = action(forKeyCode: Int(event.keyCode), flags: flags) else { return }
        Self.logger.notice("Received \(action.rawValue, privacy: .public) through NSEvent fallback")
        dispatch(action)
    }

    private func reportShortcutConflictsIfNeeded() {
        // An active session event tap receives the key before ordinary apps
        // and can discard it, so Carbon registration collisions are harmless
        // in that state. Without Accessibility, passive NSEvent monitoring
        // cannot recover a shortcut another app has already consumed.
        guard !hasPriorityGlobalHotkeys else {
            lastReportedConflictActions.removeAll()
            return
        }
        let conflicts = Set(carbonRegistrationFailures.keys)
        guard !conflicts.isEmpty, conflicts != lastReportedConflictActions else { return }
        lastReportedConflictActions = conflicts
        NotificationCenter.default.post(
            name: .hotkeyConflictsDetected,
            object: Array(conflicts).sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }
}

extension Notification.Name {
    static let hotkeyConflictsDetected = Notification.Name("hotkeyConflictsDetected")
    static let priorityHotkeyStatusChanged = Notification.Name("priorityHotkeyStatusChanged")
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.reenableEventTapAfterDisable()
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    if let modifiedEvent = manager.handleKeyEvent(event) {
        return Unmanaged.passUnretained(modifiedEvent)
    }
    return nil
}

private func carbonHotkeyCallback(
    handler: EventHandlerCallRef?,
    event: EventRef?,
    userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userInfo else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    manager.handleCarbonHotkeyEvent(event)
    return noErr
}
