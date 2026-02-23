import SwiftUI
import Cocoa

@main
struct SpaceSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItems: [NSStatusItem] = []
    var spaceManager = SpaceManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateStatusBar()
        
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatusBar()
        }
    }
    
    func updateStatusBar() {
        let spaces = spaceManager.getSpaces()
        let currentSpaceId = spaceManager.getCurrentSpaceId()
        
        // 调整 statusItems 数量
        while statusItems.count < spaces.count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItems.append(item)
        }
        while statusItems.count > spaces.count {
            if let item = statusItems.popLast() {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
        
        // 更新每个按钮（倒序显示，让桌面1在最左边）
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
                button.toolTip = String(space.id)
                button.target = self
                button.action = #selector(leftClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            
            // 清除菜单，让左键点击直接触发 action
            item.menu = nil
        }
    }
    
    @objc func leftClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let spaceNumber = sender.tag
        
        if event.type == .rightMouseUp {
            // 右键 - 重命名
            guard let spaceIdStr = sender.toolTip, let spaceId = UInt64(spaceIdStr) else { return }
            renameSpace(spaceNumber: spaceNumber, spaceId: spaceId)
        } else {
            // 左键 - 切换
            spaceManager.switchToSpace(spaceNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.updateStatusBar()
            }
        }
    }
    
    func renameSpace(spaceNumber: Int, spaceId: UInt64) {
        let currentName = spaceManager.getSpaceName(for: spaceId) ?? "\(spaceNumber)"
        
        let alert = NSAlert()
        alert.messageText = "Rename Desktop \(spaceNumber)"
        alert.informativeText = "Enter new name (leave empty to show number):"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField
        
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if newName.isEmpty {
                spaceManager.removeSapceName(for: spaceId)
            } else {
                spaceManager.setSpaceName(for: spaceId, name: newName)
            }
            updateStatusBar()
        }
    }
}
