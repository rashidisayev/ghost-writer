import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` is deprecated in spirit and unreplaced in
/// practice: `NSEvent.addGlobalMonitorForEvents` cannot *consume* the event, so
/// it can't own a shortcut. Vendored rather than pulling in HotKey/MASShortcut —
/// see docs/04-project-structure.md §3.
@MainActor
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    public struct Shortcut: Sendable, Equatable {
        public let keyCode: UInt32
        public let modifiers: UInt32
        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⌥⌘K — the default trigger.
        public static let rewrite = Shortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(optionKey | cmdKey)
        )
        /// Escape, registered only while a suggestion is showing.
        public static let dismiss = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)
        /// Tab, registered only while a suggestion is showing.
        public static let accept = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: 0)
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() { installEventHandler() }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { manager.fire(id: hotKeyID.id) }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
    }

    private func fire(id: UInt32) { handlers[id]?() }

    /// Returns a token used to unregister. Registering Tab/Esc globally is only
    /// safe while a suggestion is on screen — unregister the moment it's
    /// dismissed, or Quill swallows Tab system-wide.
    @discardableResult
    public func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x51_55_4C_4C), id: id) // 'QULL'
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }

        refs[id] = ref
        handlers[id] = action
        return id
    }

    public func unregister(_ token: UInt32) {
        if let ref = refs[token] { UnregisterEventHotKey(ref) }
        refs[token] = nil
        handlers[token] = nil
    }
}
