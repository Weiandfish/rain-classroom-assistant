import AppKit
import ScreenCaptureKit
import ApplicationServices

struct FrameLine: Codable {
    let text: String
    let x: Double
    let y: Double
}

struct Frame: Codable {
    let id: CGWindowID
    let lines: [FrameLine]
    let pending: [Detection]
}

func thumbnail(_ image: CGImage, at region: CGRect) throws -> [UInt8] {
    guard let crop = image.cropping(to: region) else { throw Problem("画面区域无效") }
    var data = [UInt8](repeating: 0, count: 32*24)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: 32, height: 24, bitsPerComponent: 8,
                                  bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0,y: 0,width: 32,height: 24))
        return true
    }
    guard ok else { throw Problem("无法比较窗口") }
    return data
}

func checkScene(_ reference: CGImage, _ live: CGImage, x: Double, y: Double) throws {
    guard reference.width == live.width, reference.height == live.height else { throw Problem("窗口尺寸已变化") }
    let bounds = CGRect(x: 0,y: 0,width: live.width,height: live.height)
    let local = CGRect(x: x*bounds.width-48, y: y*bounds.height-28, width: 96,height: 56).intersection(bounds)
    for region in [bounds, local] {
        let a = try thumbnail(reference, at: region), b = try thumbnail(live, at: region)
        let delta = zip(a,b).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }
        guard Double(delta)/Double(a.count) < 4.0 else { throw Problem("答题画面已变化，取消此次点击") }
    }
}

@available(macOS 14.0, *)
func interact(_ args: [String]) async throws {
    var window = try await targetWindow(requireFullSize: false)
    if args[0] == "focus" || (args[0] == "act" && args.count >= 2 && UInt32(args[1]) == window.windowID),
       let pid = window.owningApplication?.processID,
       (args[0] == "focus" || NSWorkspace.shared.frontmostApplication?.processIdentifier != pid) {
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        if let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let items = attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if let menu = items.first(where: { (attribute($0, kAXTitleAttribute) as? String) == "窗口" }) {
                AXUIElementPerformAction(menu, kAXPressAction as CFString)
                let children = attribute(menu, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let entries = children.flatMap { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                if let entry = entries.first(where: { (attribute($0, kAXTitleAttribute) as? String) == "长江雨课堂" }) {
                    AXUIElementPerformAction(entry, kAXPressAction as CFString)
                } else { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            }
        }
        try await Task.sleep(for: .milliseconds(650))
        window = try await targetWindow()
    }
    if args[0] == "focus" { return }
    guard window.frame.width >= 280 else { throw Problem("课堂窗口已缩小，请恢复为正常大小") }
    let image = try await capture(window)
    if args[0] == "frame" {
        guard args.count == 3 else { throw Problem("frame 需要课程名和临时图片路径") }
        let lines = try readText(image)
        let info = Frame(id: window.windowID,
                         lines: lines.map { FrameLine(text: $0.text,x: $0.box.midX,y: $0.box.midY) },
                         pending: try detect(image, course: args[1]))
        guard !lines.isEmpty, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Problem("无法读取课堂画面") }
        try png.write(to: URL(fileURLWithPath: args[2]),options: .atomic)
        FileHandle.standardOutput.write(try JSONEncoder().encode(info))
        return
    }
    guard (args.count == 5 || args.count == 6), UInt32(args[1]) == window.windowID,
          let x = Double(args[3]),let y = Double(args[4]), (0.02...0.98).contains(x), (0.018...0.99).contains(y),
          let pid = window.owningApplication?.processID else { throw Problem("点击目标不匹配") }
    try checkScene(loadImage(args[2]), image, x: x, y: y)
    let point = CGPoint(x: window.frame.minX+x*window.frame.width, y: window.frame.minY+y*window.frame.height)
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],0) as? [[String: Any]] ?? []
    let hit = windows.first { w in
        guard (w["kCGWindowLayer"] as? Int ?? -1) >= 0, (w["kCGWindowAlpha"] as? Double ?? 0) > 0.01,
              let rect = w["kCGWindowBounds"] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rect) else { return false }
        return bounds.contains(point)
    }
    guard hit?["kCGWindowNumber"] as? UInt32 == window.windowID,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          CGPreflightPostEventAccess() else { throw Problem("课堂窗口需要位于前台且允许辅助功能控制 (目标 \(window.windowID)/\(pid)，命中 \(hit?["kCGWindowNumber"] ?? "-")，前台 \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)，点 \(point)，权限 \(CGPreflightPostEventAccess()))") }
    for kind: CGEventType in [.leftMouseDown,.leftMouseUp] {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left) else { throw Problem("无法创建点击事件") }
        event.postToPid(pid)
    }
    if args.count == 6 {
        guard !args[5].isEmpty, args[5].count <= 1000 else { throw Problem("答案长度异常") }
        try await Task.sleep(for: .milliseconds(200))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              try await targetWindow().windowID == window.windowID else { throw Problem("输入焦点已变化") }
        let chars = Array(args[5].utf16)
        for down in [true,false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw Problem("无法创建输入事件") }
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            event.postToPid(pid)
        }
    }
}
