import Foundation
import AppKit
import Vision
import ImageIO

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Line {
    let text: String
    let box: CGRect // normalized, origin at top left
}

func readText(_ image: CGImage) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap {
        guard let candidate = $0.topCandidates(1).first else { return nil }
        let box = $0.boundingBox
        return Line(text: candidate.string, box: CGRect(x: box.minX, y: 1-box.maxY, width: box.width, height: box.height))
    }
}

// Downsample in sRGB. A pending card has a wide saturated blue band.
// Skip the blue navigation bar. Completed cards are much less saturated.
func blueBands(_ image: CGImage) throws -> [ClosedRange<Double>] {
    let w = 96, h = 192
    var bytes = [UInt8](repeating: 0, count: w*h*4)
    try bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Problem("颜色采样失败") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var result = [ClosedRange<Double>]()
    var start: Int?
    for y in 18...h {
        var hits = 0
        if y < h {
            for x in 7..<86 {
                let i = 4*(y*w+x), r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
                if b > 180 && b-r > 65 && b-g > 34 { hits += 1 }
            }
        }
        if hits >= 42 {
            if start == nil { start = y }
        } else if let first = start {
            if y-first >= 7 { result.append(Double(first)/Double(h)...Double(y)/Double(h)) }
            start = nil
        }
    }
    return result
}

func compact(_ text: String) -> String {
    text.filter { !$0.isWhitespace }.precomposedStringWithCompatibilityMapping
}

struct Detection: Codable, Equatable {
    let page: String
    let status: String
    let x: Double
    let y: Double
}

func classroomHeader(_ image: CGImage, course: String) throws -> Bool {
    let region = CGRect(x: 0, y: 0, width: image.width, height: max(1, image.height/6))
    guard let header = image.cropping(to: region) else { return false }
    let labels = try readText(header).map { compact($0.text) }
    return labels.contains(compact(course)) && labels.contains("习题") && labels.contains("PPT")
}

// The caller has verified the course on the cropped header. Recognize each
// candidate on its own: full-frame Vision can misread the same title and tabs.
func pendingCards(_ image: CGImage) throws -> [Detection] {
    var detections = [Detection]()
    for band in try blueBands(image) {
        let h = CGFloat(image.height)
        let rect = CGRect(x: 0, y: max(0, band.lowerBound*h-3), width: CGFloat(image.width),
                          height: (band.upperBound-band.lowerBound)*h+6)
        guard let card = image.cropping(to: rect) else { continue }
        let lines = try readText(card)
        guard lines.contains(where: { compact($0.text).contains("课堂习题") }),
              lines.contains(where: { $0.box.midX > 0.57 && compact($0.text).contains("未完成") }) else { continue }
        let pageLine = lines.first { compact($0.text).range(of: "^P[0-9]+$", options: [.regularExpression,.caseInsensitive]) != nil }
        let page = pageLine.map { compact($0.text).uppercased() } ?? "未知页码"
        detections.append(Detection(page: page, status: "未完成", x: 0.5, y: rect.midY/h))
    }
    return detections
}

struct ClassroomWindow {
    let windowID: CGWindowID
    let frame: CGRect
    let owningApplication: NSRunningApplication?
    var fullSize: Bool { frame.width >= 280 && frame.height >= 350 }
}

func targetWindow(requireFullSize: Bool = true) throws -> ClassroomWindow {
    let rows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements], 0) as? [[String:Any]] ?? []
    let windows = rows.compactMap { row -> ClassroomWindow? in
        guard row["kCGWindowName"] as? String == "长江雨课堂",
              let pid = row["kCGWindowOwnerPID"] as? pid_t,
              let app = NSRunningApplication(processIdentifier: pid),
              ["com.tencent.xinWeChat","com.tencent.flue.WeApp"].contains(app.bundleIdentifier ?? ""),
              let id = row["kCGWindowNumber"] as? CGWindowID,
              let box = row["kCGWindowBounds"] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation:box) else { return nil }
        return ClassroomWindow(windowID:id, frame:frame, owningApplication:app)
    }
    guard windows.count == 1 else { throw Problem("课堂窗口数量为 \(windows.count)，等待唯一的长江雨课堂窗口") }
    let window = windows[0]
    guard !requireFullSize || window.fullSize else { throw Problem("课堂窗口已缩小，请恢复为正常大小") }
    return window
}

func capture(_ window: ClassroomWindow) async throws -> CGImage {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("frame.png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l" + String(window.windowID), file.path]
    task.standardError = FileHandle.nullDevice
    try task.run()
    for _ in 0..<60 {
        if !task.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    if task.isRunning { task.terminate(); throw Problem("系统窗口采集超时") }
    guard task.terminationStatus == 0 else { throw Problem("课堂截图失败，请检查窗口和录屏权限") }
    let image = try loadImage(file.path)
    guard image.width >= 280, image.height >= 350 else { throw Problem("课堂窗口已缩小，请恢复为正常大小") }
    return image
}

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Problem("无法读取图片") }
    return image
}

func emit(_ state: String, _ detections: [Detection] = [], detail: String = "") {
    struct Event: Encodable {
        let time: String
        let state: String
        let cards: [Detection]
        let detail: String
    }
    let event = Event(time: ISO8601DateFormatter().string(from: Date()), state: state, cards: detections, detail: detail)
    if let data = try? JSONEncoder().encode(event) { FileHandle.standardOutput.write(data + Data([10])) }
}

@main
struct Watcher {
    static func main() async {
        _ = NSApplication.shared
        do {
            guard #available(macOS 14.0, *) else { throw Problem("需要 macOS 14 或更高版本") }
            let args = Array(CommandLine.arguments.dropFirst())
            guard let mode = args.first, ["inspect","check","watch","frame","act","focus","recovery-frame","reload"].contains(mode) else { throw Problem("用法: rainwatch inspect|check [课程名] [窗口图片] 或 rainwatch watch [课程名]") }
            if ["frame","act","focus","recovery-frame","reload"].contains(mode) {
                try await interact(args)
                return
            }
            let course = args.count > 1 ? args[1] : "人工智能精通I"
            repeat {
                do {
                    let image: CGImage
                    if args.count == 3 && mode != "watch" { image = try loadImage(args[2]) }
                    else { image = try await capture(targetWindow()) }
                    if mode == "inspect" { for line in try readText(image) { print(line.text) }; return }
                    guard try classroomHeader(image, course: course) else {
                        let text = try readText(image).map { compact($0.text) }
                        if text.contains(where: { ["课堂已结束","本次课堂已结束","本次授课已结束","老师已下课"].contains($0) }) {
                            emit("ended")
                            return
                        }
                        throw Problem("未看到指定课程的课堂列表")
                    }
                    let cards = try pendingCards(image)
                    let state = cards.isEmpty ? "no_match" : "pending"
                    emit(state, cards)
                } catch {
                    if mode != "watch" { throw error }
                    let message = error.localizedDescription
                    emit("unavailable", detail: message)
                }
                if mode == "watch" { try await Task.sleep(for: .seconds(5)) }
            } while mode == "watch"
        } catch { emit("error", detail: error.localizedDescription); exit(1) }
    }
}
