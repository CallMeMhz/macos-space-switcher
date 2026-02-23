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
        .defaultSize(width: 400, height: 450)
    }
}

class SpaceManager: ObservableObject {
    
    // MARK: - Private API
    
    private let skylight: UnsafeMutableRawPointer?
    
    private typealias CGSMainConnectionIDFunc = @convention(c) () -> UInt32
    private typealias CGSGetActiveSpaceFunc = @convention(c) (UInt32) -> UInt64
    
    private let CGSMainConnectionID: CGSMainConnectionIDFunc?
    private let CGSGetActiveSpace: CGSGetActiveSpaceFunc?
    
    // MARK: - Storage
    
    private let spaceNamesKey = "SpaceNames"
    
    @Published var spaces: [SpaceInfo] = []
    @Published var currentSpaceId: UInt64 = 0
    
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
        spaces = getSpaces()
        currentSpaceId = getCurrentSpaceId()
    }
    
    // MARK: - Get Spaces
    
    func getSpaces() -> [SpaceInfo] {
        var spaces: [SpaceInfo] = []
        
        guard let spacesDict = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration"),
              let managementData = spacesDict["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return spaces
        }
        
        let currentSpaceId = getCurrentSpaceId()
        
        for monitor in monitors {
            guard let displayId = monitor["Display Identifier"] as? String,
                  displayId == "Main",
                  let spacesList = monitor["Spaces"] as? [[String: Any]] else {
                continue
            }
            
            for (index, spaceDict) in spacesList.enumerated() {
                guard let spaceId = spaceDict["ManagedSpaceID"] as? UInt64 ?? (spaceDict["id64"] as? UInt64) else {
                    continue
                }
                
                let space = SpaceInfo(
                    id: spaceId,
                    index: index,
                    isCurrent: spaceId == currentSpaceId
                )
                spaces.append(space)
            }
            break
        }
        
        return spaces
    }
    
    func getCurrentSpaceId() -> UInt64 {
        guard let CGSMainConnectionID = CGSMainConnectionID,
              let CGSGetActiveSpace = CGSGetActiveSpace else {
            return 0
        }
        
        let conn = CGSMainConnectionID()
        return CGSGetActiveSpace(conn)
    }
    
    func getCurrentSpaceIndex() -> Int {
        let spaces = getSpaces()
        let currentId = getCurrentSpaceId()
        
        for (index, space) in spaces.enumerated() {
            if space.id == currentId {
                return index + 1
            }
        }
        return 1
    }
    
    // MARK: - Switch Space
    
    func switchToSpace(_ number: Int) {
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

struct SpaceInfo: Identifiable {
    let id: UInt64
    let index: Int
    var isCurrent: Bool
}

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
        let spaces = spaceManager.getSpaces()
        let currentSpaceId = spaceManager.getCurrentSpaceId()
        
        while statusItems.count < spaces.count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItems.append(item)
        }
        while statusItems.count > spaces.count {
            if let item = statusItems.popLast() {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        
        for (index, space) in spaces.enumerated() {
            let item = statusItems[spaces.count - 1 - index]
            let spaceNumber = index + 1
            let isCurrent = space.id == currentSpaceId
            let name = spaceManager.getSpaceName(for: space.id) ?? "\(spaceNumber)"
            
            if let button = item.button {
                if isCurrent {
                    button.title = "[\(name)]"
                } else {
                    button.title = " \(name) "
                }
                
                button.tag = spaceNumber
                button.target = self
                button.action = #selector(switchSpace(_:))
            }
            
            item.menu = nil
        }
    }
    
    @objc func switchSpace(_ sender: NSStatusBarButton) {
        let spaceNumber = sender.tag
        spaceManager.switchToSpace(spaceNumber)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateStatusBar()
        }
    }
}

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
                ForEach(Array(spaceManager.spaces.enumerated()), id: \.element.id) { index, space in
                    HStack {
                        Text("Desktop \(index + 1)")
                            .frame(width: 80, alignment: .leading)
                        
                        TextField("Name", text: binding(for: space.id, index: index + 1))
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        
                        if space.id == spaceManager.currentSpaceId {
                            Text("●")
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 250)
            
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
        .frame(width: 400, height: 450)
        .onAppear {
            loadNames()
        }
        .onReceive(timer) { _ in
            hasAccessibility = AXIsProcessTrusted()
        }
    }
    
    func loadNames() {
        for space in spaceManager.spaces {
            if let name = spaceManager.getSpaceName(for: space.id) {
                names[space.id] = name
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
