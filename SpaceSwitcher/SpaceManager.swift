import Foundation
import Cocoa

struct SpaceInfo {
    let id: UInt64
    let index: Int
    var isCurrent: Bool
}

class SpaceManager {
    
    // MARK: - Private API
    
    private let skylight: UnsafeMutableRawPointer?
    
    private typealias CGSMainConnectionIDFunc = @convention(c) () -> UInt32
    private typealias CGSGetActiveSpaceFunc = @convention(c) (UInt32) -> UInt64
    
    private let CGSMainConnectionID: CGSMainConnectionIDFunc?
    private let CGSGetActiveSpace: CGSGetActiveSpaceFunc?
    
    // MARK: - Storage
    
    private let spaceNamesKey = "SpaceNames"
    
    init() {
        skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        
        if let skylight = skylight {
            CGSMainConnectionID = unsafeBitCast(dlsym(skylight, "CGSMainConnectionID"), to: CGSMainConnectionIDFunc.self)
            CGSGetActiveSpace = unsafeBitCast(dlsym(skylight, "CGSGetActiveSpace"), to: CGSGetActiveSpaceFunc.self)
        } else {
            CGSMainConnectionID = nil
            CGSGetActiveSpace = nil
        }
    }
    
    // MARK: - Get Spaces
    
    func getSpaces() -> [SpaceInfo] {
        var spaces: [SpaceInfo] = []
        
        // 读取 com.apple.spaces 配置
        guard let spacesDict = UserDefaults(suiteName: "com.apple.spaces")?.dictionary(forKey: "SpacesDisplayConfiguration"),
              let managementData = spacesDict["Management Data"] as? [String: Any],
              let monitors = managementData["Monitors"] as? [[String: Any]] else {
            return spaces
        }
        
        let currentSpaceId = getCurrentSpaceId()
        
        // 找到主显示器
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
        // Key codes for numbers 1-0
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
    }
    
    func removeSapceName(for spaceId: UInt64) {
        var names = UserDefaults.standard.dictionary(forKey: spaceNamesKey) as? [String: String] ?? [:]
        names.removeValue(forKey: String(spaceId))
        UserDefaults.standard.set(names, forKey: spaceNamesKey)
    }
}
