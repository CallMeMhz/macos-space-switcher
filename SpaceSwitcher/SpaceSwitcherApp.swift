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
    var xPosition: CGFloat = 0
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
    private typealias CGSCopyManagedDisplaySpacesFunc = @convention(c) (UInt32) -> CFArray?
    
    private let CGSMainConnectionID: CGSMainConnectionIDFunc?
    private let CGSGetActiveSpace: CGSGetActiveSpaceFunc?
    private let CGSCopyManagedDisplaySpaces: CGSCopyManagedDisplaySpacesFunc?
    
    private let spaceNamesKey = "SpaceNames"
    
    @Published var displays: [DisplayInfo] = []
    
    // Cache display order to prevent flickering during space switch
    private var cachedDisplayOrder: [String] = []
    private var lastScreenCount: Int = 0
    
    init() {
        skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        
        if let skylight = skylight {
            CGSMainConnectionID = unsafeBitCast(dlsym(skylight, "CGSMainConnectionID"), to: CGSMainConnectionIDFunc.self)
            CGSGetActiveSpace = unsafeBitCast(dlsym(skylight, "CGSGetActiveSpace"), to: CGSGetActiveSpaceFunc.self)
            CGSCopyManagedDisplaySpaces = unsafeBitCast(dlsym(skylight, "CGSCopyManagedDisplaySpaces"), to: CGSCopyManagedDisplaySpacesFunc.self)
        } else {
            CGSMainConnectionID = nil
            CGSGetActiveSpace = nil
            CGSCopyManagedDisplaySpaces = nil
        }
        
        refresh()
    }
    
    func refresh() {
        displays = getDisplays()
    }
    
    func getDisplays() -> [DisplayInfo] {
        var result: [DisplayInfo] = []
        
        // Use UserDefaults for spaces list (matches keyboard shortcut order)
        guard let spacesDict = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration"),
              let managementData = spacesDict["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return result
        }
        
        // Get real-time current space IDs from private API
        let currentSpaceIds = getCurrentSpaceIds()
        
        // Build screen info map using CGMainDisplayID for stable main display detection
        let mainDisplayID = CGMainDisplayID()
        var screenInfoByUUID: [String: (x: CGFloat, name: String)] = [:]
        var mainScreenInfo: (x: CGFloat, name: String)? = nil
        
        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            if screenNumber == mainDisplayID {
                mainScreenInfo = (x: screen.frame.origin.x, name: screen.localizedName)
            } else {
                // Store by screen number for non-main screens
                screenInfoByUUID[String(screenNumber)] = (x: screen.frame.origin.x, name: screen.localizedName)
            }
        }
        
        // Get non-main screens sorted by x position for consistent matching
        let nonMainScreens = NSScreen.screens.filter { 
            let screenNumber = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return screenNumber != mainDisplayID
        }.sorted { $0.frame.origin.x < $1.frame.origin.x }
        var nonMainIndex = 0
        
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
            var displayCurrentSpaceId: UInt64 = 0
            
            for (index, spaceDict) in spacesList.enumerated() {
                guard let spaceId = spaceDict["ManagedSpaceID"] as? UInt64 ?? (spaceDict["id64"] as? UInt64) else {
                    continue
                }
                
                // Check if this space is current using real-time API
                let isCurrent = currentSpaceIds.contains(spaceId)
                if isCurrent {
                    displayCurrentSpaceId = spaceId
                }
                
                let space = SpaceInfo(
                    id: spaceId,
                    index: index,
                    displayId: displayId,
                    isCurrent: isCurrent
                )
                spaces.append(space)
            }
            
            // Find screen position and name for this display
            var xPosition: CGFloat = 0
            var displayName = "Display"
            
            if displayId == "Main" {
                if let info = mainScreenInfo {
                    xPosition = info.x
                    displayName = info.name
                }
            } else {
                // Match with non-main screens by order
                if nonMainIndex < nonMainScreens.count {
                    let screen = nonMainScreens[nonMainIndex]
                    xPosition = screen.frame.origin.x
                    displayName = screen.localizedName
                    nonMainIndex += 1
                }
            }
            
            let display = DisplayInfo(
                id: displayId,
                name: displayName,
                spaces: spaces,
                currentSpaceId: displayCurrentSpaceId,
                xPosition: xPosition
            )
            result.append(display)
        }
        
        // Sort by screen position for display only
        result.sort { $0.xPosition < $1.xPosition }
        
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
    
    // Get current space ID for each display using private API
    // Returns mapping by space ID instead of display ID for reliable matching
    func getCurrentSpaceIds() -> Set<UInt64> {
        var result: Set<UInt64> = []
        
        guard let CGSMainConnectionID = CGSMainConnectionID,
              let CGSCopyManagedDisplaySpaces = CGSCopyManagedDisplaySpaces else {
            return result
        }
        
        let conn = CGSMainConnectionID()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else {
            return result
        }
        
        for displayInfo in displaySpaces {
            if let currentSpace = displayInfo["Current Space"] as? [String: Any],
               let spaceId = currentSpace["ManagedSpaceID"] as? UInt64 ?? (currentSpace["id64"] as? UInt64) {
                result.insert(spaceId)
            }
        }
        
        return result
    }
    
    // Get displays in system original order (for keyboard shortcut mapping)
    func getDisplaysInSystemOrder() -> [DisplayInfo] {
        var result: [DisplayInfo] = []
        
        guard let spacesDict = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration"),
              let managementData = spacesDict["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return result
        }
        
        for monitor in monitors {
            guard let displayId = monitor["Display Identifier"] as? String,
                  let spacesList = monitor["Spaces"] as? [[String: Any]],
                  !spacesList.isEmpty else {
                continue
            }
            
            if monitor["Collapsed Space"] != nil {
                continue
            }
            
            var spaces: [SpaceInfo] = []
            for (index, spaceDict) in spacesList.enumerated() {
                guard let spaceId = spaceDict["ManagedSpaceID"] as? UInt64 ?? (spaceDict["id64"] as? UInt64) else {
                    continue
                }
                spaces.append(SpaceInfo(id: spaceId, index: index, displayId: displayId, isCurrent: false))
            }
            
            result.append(DisplayInfo(id: displayId, name: "", spaces: spaces, currentSpaceId: 0, xPosition: 0))
        }
        
        return result
    }
    
    func switchToSpaceBySpaceId(_ spaceId: UInt64) {
        // Use system order to find the correct keyboard shortcut index
        let systemOrderDisplays = getDisplaysInSystemOrder()
        var totalIndex = 0
        
        for display in systemOrderDisplays {
            for space in display.spaces {
                totalIndex += 1
                if space.id == spaceId {
                    if totalIndex <= 10 {
                        sendSpaceSwitch(totalIndex)
                    }
                    return
                }
            }
        }
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
    var spaceIdMap: [Int: UInt64] = [:] // tag -> spaceId mapping
    
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
        
        // Reset space ID mapping
        spaceIdMap.removeAll()
        
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
        
        // statusItems[0] appears rightmost, so we fill in reverse
        // Visual: [1][2][3] | [1][2][3]  (left to right)
        // Array:  [5][4][3][sep][2][1][0] indices
        
        var itemIndex = totalItems - 1
        
        for (displayIndex, display) in displays.enumerated() {
            for (spaceIndex, space) in display.spaces.enumerated() {
                guard itemIndex >= 0 else { continue }
                
                let item = statusItems[itemIndex]
                let name = spaceManager.getSpaceName(for: space.id) ?? "\(spaceIndex + 1)"
                let isCurrent = space.isCurrent
                
                spaceIdMap[itemIndex] = space.id
                
                if let button = item.button {
                    button.image = createButtonImage(title: name, isCurrent: isCurrent)
                    button.imagePosition = .imageOnly
                    button.tag = itemIndex
                    button.target = self
                    button.action = #selector(switchSpace(_:))
                }
                
                itemIndex -= 1
            }
            
            // Add separator
            if displayIndex < displays.count - 1 {
                guard itemIndex >= 0 else { continue }
                let item = statusItems[itemIndex]
                if let button = item.button {
                    button.image = createSeparatorImage()
                    button.imagePosition = .imageOnly
                    button.target = nil
                    button.action = nil
                }
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
        let tag = sender.tag
        if let spaceId = spaceIdMap[tag] {
            spaceManager.switchToSpaceBySpaceId(spaceId)
        }
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
                .padding(.bottom, 15)
            
            Divider()
            
            // Multi-column layout for displays
            HStack(alignment: .top, spacing: 0) {
                ForEach(spaceManager.displays) { display in
                    DisplayColumnView(
                        display: display,
                        names: $names,
                        spaceManager: spaceManager
                    )
                    
                    if display.id != spaceManager.displays.last?.id {
                        Divider()
                    }
                }
            }
            .frame(minHeight: 280)
            .padding(.horizontal, 10)
            
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
        .frame(width: CGFloat(max(400, spaceManager.displays.count * 200)), height: 500)
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
}

struct DisplayColumnView: View {
    let display: DisplayInfo
    @Binding var names: [UInt64: String]
    let spaceManager: SpaceManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Display header
            Text(display.name)
                .font(.headline)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
            
            // Desktop list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(display.spaces.enumerated()), id: \.element.id) { index, space in
                        HStack {
                            Text("\(index + 1)")
                                .frame(width: 24)
                                .foregroundColor(.secondary)
                            
                            TextField("Name", text: binding(for: space.id, index: index + 1))
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            
                            if space.id == display.currentSpaceId {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 180)
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
