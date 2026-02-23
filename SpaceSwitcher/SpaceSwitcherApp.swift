import SwiftUI
import Cocoa
import ApplicationServices

@main
struct SpaceSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("SpaceSwitcher Settings", id: "settings") {
            SettingsContentView()
                .environmentObject(appDelegate.spaceManager)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appDelegate.refreshSettingsView()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 400, height: 500)
    }
}

// MARK: - Display & Space Info

struct DisplayInfo: Identifiable {
    let id: String
    let name: String
    var spaces: [SpaceInfo]
    var currentSpaceId: UInt64
}

struct SpaceInfo: Identifiable {
    let id: UInt64
    let index: Int
    let displayId: String
    var isCurrent: Bool
}

// MARK: - Space Button View

class SpaceButtonView: NSView {
    var title: String = ""
    var isCurrent: Bool = false
    var onClick: (() -> Void)?
    
    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (title as NSString).size(withAttributes: attrs)
        return NSSize(width: size.width + 12, height: 18)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let rect = bounds.insetBy(dx: 1, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        
        if isCurrent {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
            path.fill()
            NSColor.white.setFill()
        } else {
            NSColor.gray.withAlphaComponent(0.3).setFill()
            path.fill()
            NSColor.labelColor.setFill()
        }
        
        let font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .bold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isCurrent ? NSColor.white : NSColor.labelColor
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (title as NSString).draw(at: point, withAttributes: attrs)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Highlight on click
    }
    
    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onClick?()
        }
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - Space Manager

class SpaceManager: ObservableObject {
    
    private let skylight: UnsafeMutableRawPointer?
    
    private typealias CGSMainConnectionIDFunc = @convention(c) () -> UInt32
    private typealias CGSGetActiveSpaceFunc = @convention(c) (UInt32) -> UInt64
    
    private let CGSMainConnectionID: CGSMainConnectionIDFunc?
    private let CGSGetActiveSpace: CGSGetActiveSpaceFunc?
    
    private let spaceNamesKey = "SpaceNames"
    
    @Published var displays: [DisplayInfo] = []
    
    init() {
        skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        
        if let skylight = skylight {
            CGSMainConnectionID = unsafeBitCast(dlsym(skylight, "CGSMainConnectionID"), to: CGSMainConnectionIDFunc.self)
            CGSGetActiveSpace = unsafeBitCast(dlsym(skylight, "CGSGetActiveSpace"), to: CGSGetActiveSpaceFunc.self)
        } else {
            CGSMainConnectionID = nil
            CGSGetActiveSpace = nil
        }
        
        refresh()
    }
    
    func refresh() {
        displays = getDisplays()
    }
    
    func getDisplays() -> [DisplayInfo] {
        var result: [DisplayInfo] = []
        
        guard let spacesDict = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration"),
              let managementData = spacesDict["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return result
        }
        
        let currentSpaceId = getCurrentSpaceId()
        
        for monitor in monitors {
            guard let displayId = monitor["Display Identifier"] as? String,
                  let spacesList = monitor["Spaces"] as? [[String: Any]],
                  !spacesList.isEmpty else {
                continue
            }
            
            // Skip collapsed spaces (disconnected monitors)
            if monitor["Collapsed Space"] != nil {
                continue
            }
            
            var spaces: [SpaceInfo] = []
            for (index, spaceDict) in spacesList.enumerated() {
                guard let spaceId = spaceDict["ManagedSpaceID"] as? UInt64 ?? (spaceDict["id64"] as? UInt64) else {
                    continue
                }
                
                let space = SpaceInfo(
                    id: spaceId,
                    index: index,
                    displayId: displayId,
                    isCurrent: spaceId == currentSpaceId
                )
                spaces.append(space)
            }
            
            // Get current space for this display
            var displayCurrentSpaceId: UInt64 = 0
            if let currentSpace = monitor["Current Space"] as? [String: Any],
               let spaceId = currentSpace["ManagedSpaceID"] as? UInt64 ?? (currentSpace["id64"] as? UInt64) {
                displayCurrentSpaceId = spaceId
            }
            
            let displayName = displayId == "Main" ? "Main" : "Display \(result.count + 1)"
            let display = DisplayInfo(
                id: displayId,
                name: displayName,
                spaces: spaces,
                currentSpaceId: displayCurrentSpaceId
            )
            result.append(display)
        }
        
        return result
    }
    
    func getCurrentSpaceId() -> UInt64 {
        guard let CGSMainConnectionID = CGSMainConnectionID,
              let CGSGetActiveSpace = CGSGetActiveSpace else {
            return 0
        }
        
        let conn = CGSMainConnectionID()
        return CGSGetActiveSpace(conn)
    }
    
    func switchToSpace(displayIndex: Int, spaceIndex: Int) {
        // For main display, use Ctrl + number
        // For secondary display, we need to focus that display first, then switch
        // For now, we only support 10 spaces total across displays
        
        var totalIndex = 0
        for (dIndex, display) in displays.enumerated() {
            for (sIndex, _) in display.spaces.enumerated() {
                totalIndex += 1
                if dIndex == displayIndex && sIndex == spaceIndex {
                    if totalIndex <= 10 {
                        sendSpaceSwitch(totalIndex)
                    }
                    return
                }
            }
        }
    }
    
    func switchToSpaceById(displayId: String, spaceIndex: Int) {
        // Calculate the global space index
        var totalIndex = 0
        for display in displays {
            for (sIndex, _) in display.spaces.enumerated() {
                totalIndex += 1
                if display.id == displayId && sIndex == spaceIndex {
                    if totalIndex <= 10 {
                        sendSpaceSwitch(totalIndex)
                    }
                    return
                }
            }
        }
    }
    
    func switchToSpaceByGlobalIndex(_ globalIndex: Int) {
        if globalIndex >= 1 && globalIndex <= 10 {
            sendSpaceSwitch(globalIndex)
        }
    }
    
    private func sendSpaceSwitch(_ number: Int) {
        let keyCodes: [Int: UInt16] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25, 10: 29
        ]
        
        guard let keyCode = keyCodes[number] else { return }
        
        let src = CGEventSource(stateID: .hidSystemState)
        
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        
        keyDown?.flags = .maskControl
        keyUp?.flags = .maskControl
        
        keyDown?.post(tap: .cghidEventTap)
        usleep(50000)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    // MARK: - Space Names
    
    func getSpaceName(for spaceId: UInt64) -> String? {
        let names = UserDefaults.standard.dictionary(forKey: spaceNamesKey) as? [String: String] ?? [:]
        return names[String(spaceId)]
    }
    
    func setSpaceName(for spaceId: UInt64, name: String) {
        var names = UserDefaults.standard.dictionary(forKey: spaceNamesKey) as? [String: String] ?? [:]
        names[String(spaceId)] = name
        UserDefaults.standard.set(names, forKey: spaceNamesKey)
        objectWillChange.send()
    }
    
    func removeSpaceName(for spaceId: UInt64) {
        var names = UserDefaults.standard.dictionary(forKey: spaceNamesKey) as? [String: String] ?? [:]
        names.removeValue(forKey: String(spaceId))
        UserDefaults.standard.set(names, forKey: spaceNamesKey)
        objectWillChange.send()
    }
    
    func resetAllNames() {
        UserDefaults.standard.removeObject(forKey: spaceNamesKey)
        objectWillChange.send()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItems: [NSStatusItem] = []
    var spaceManager = SpaceManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusBar()
        
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatusBar()
        }
    }
    
    func refreshSettingsView() {
        spaceManager.refresh()
    }
    
    func updateStatusBar() {
        let displays = spaceManager.getDisplays()
        let currentSpaceId = spaceManager.getCurrentSpaceId()
        
        // Calculate total items needed: spaces + separators between displays
        var totalItems = 0
        for (index, display) in displays.enumerated() {
            totalItems += display.spaces.count
            if index < displays.count - 1 {
                totalItems += 1 // separator
            }
        }
        
        // Adjust statusItems count
        while statusItems.count < totalItems {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItems.append(item)
        }
        while statusItems.count > totalItems {
            if let item = statusItems.popLast() {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        
        // Build items in reverse order (so first display appears on left)
        var itemIndex = totalItems - 1
        var globalSpaceIndex = 0
        
        for (displayIndex, display) in displays.enumerated() {
            // Add spaces for this display
            for (spaceIndex, space) in display.spaces.enumerated() {
                globalSpaceIndex += 1
                guard itemIndex >= 0 && itemIndex < statusItems.count else { continue }
                
                let item = statusItems[itemIndex]
                let name = spaceManager.getSpaceName(for: space.id) ?? "\(spaceIndex + 1)"
                let isCurrent = space.id == currentSpaceId
                
                if let button = item.button {
                    button.subviews.forEach { $0.removeFromSuperview() }
                    button.title = ""
                    button.image = createButtonImage(title: name, isCurrent: isCurrent)
                    button.imagePosition = .imageOnly
                    
                    button.tag = globalSpaceIndex
                    button.target = self
                    button.action = #selector(switchSpace(_:))
                }
                
                item.menu = nil
                itemIndex -= 1
            }
            
            // Add separator after display (except for last one)
            if displayIndex < displays.count - 1 {
                guard itemIndex >= 0 && itemIndex < statusItems.count else { continue }
                
                let item = statusItems[itemIndex]
                
                if let button = item.button {
                    button.subviews.forEach { $0.removeFromSuperview() }
                    button.title = ""
                    button.image = createSeparatorImage()
                    button.imagePosition = .imageOnly
                    button.target = nil
                    button.action = nil
                }
                
                item.menu = nil
                itemIndex -= 1
            }
        }
    }
    
    func createButtonImage(title: String, isCurrent: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (title as NSString).size(withAttributes: attrs)
        
        let padding: CGFloat = 6
        let height: CGFloat = 18
        let width = textSize.width + padding * 2
        
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bgRect = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
            
            if isCurrent {
                NSColor.controlAccentColor.setFill()
                path.fill()
            } else {
                NSColor.gray.withAlphaComponent(0.3).setFill()
                path.fill()
                NSColor.gray.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            
            let textColor = isCurrent ? NSColor.white : NSColor.labelColor
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let textPoint = NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            )
            (title as NSString).draw(at: textPoint, withAttributes: textAttrs)
            
            return true
        }
        
        image.isTemplate = false
        return image
    }
    
    func createSeparatorImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 18), flipped: false) { rect in
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: 4))
            path.line(to: NSPoint(x: rect.midX, y: rect.height - 4))
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
    
    @objc func switchSpace(_ sender: NSStatusBarButton) {
        let globalIndex = sender.tag
        spaceManager.switchToSpaceByGlobalIndex(globalIndex)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateStatusBar()
        }
    }
}

// MARK: - Settings View

struct SettingsContentView: View {
    @EnvironmentObject var spaceManager: SpaceManager
    @State private var names: [UInt64: String] = [:]
    @State private var hasAccessibility: Bool = AXIsProcessTrusted()
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            Text("SpaceSwitcher")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 20)
            
            Text("Click desktop in menu bar to switch")
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            
            Divider()
            
            List {
                ForEach(spaceManager.displays) { display in
                    Section(header: Text(display.name).font(.headline)) {
                        ForEach(Array(display.spaces.enumerated()), id: \.element.id) { index, space in
                            HStack {
                                Text("Desktop \(index + 1)")
                                    .frame(width: 80, alignment: .leading)
                                
                                TextField("Name", text: binding(for: space.id, index: index + 1))
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                
                                if space.id == display.currentSpaceId {
                                    Text("●")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            
            Divider()
            
            HStack {
                if hasAccessibility {
                    Button("Reset All Names") {
                        spaceManager.resetAllNames()
                        names.removeAll()
                    }
                } else {
                    Button("⛔ Open Accessibility Settings") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Spacer()
                
                Button("Quit App") {
                    NSApp.terminate(nil)
                }
                .foregroundColor(.red)
            }
            .padding(20)
        }
        .frame(width: 400, height: 500)
        .onAppear {
            loadNames()
        }
        .onReceive(timer) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }
    
    func loadNames() {
        for display in spaceManager.displays {
            for space in display.spaces {
                if let name = spaceManager.getSpaceName(for: space.id) {
                    names[space.id] = name
                }
            }
        }
    }
    
    func binding(for spaceId: UInt64, index: Int) -> Binding<String> {
        Binding(
            get: { names[spaceId] ?? "" },
            set: { newValue in
                names[spaceId] = newValue
                if newValue.isEmpty {
                    spaceManager.removeSpaceName(for: spaceId)
                } else {
                    spaceManager.setSpaceName(for: spaceId, name: newValue)
                }
            }
        )
    }
}
