import Foundation
import AppKit
import ScreenCaptureKit
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
}

func detect(_ image: CGImage, course: String) throws -> [Detection] {
    let bands = try blueBands(image)
    guard !bands.isEmpty else { return [] }
    let lines = try readText(image)
    guard lines.contains(where: { $0.box.midY < 0.12 && compact($0.text) == compact(course) }) else { return [] }
    var detections = [Detection]()
    for band in bands {
        let card = lines.filter { band.contains($0.box.midY) }
        guard card.contains(where: { compact($0.text).contains("课堂习题") }),
              card.contains(where: { $0.box.midX > 0.57 && compact($0.text).contains("未完成") }) else { continue }
        let page = card.map { compact($0.text) }.first { $0.range(of: "^P[0-9]+$", options: [.regularExpression,.caseInsensitive]) != nil } ?? "未知页码"
        detections.append(Detection(page: page, status: "未完成"))
    }
    return detections
}

@available(macOS 14.0, *)
func targetWindow(requireFullSize: Bool = true) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let windows = content.windows.filter {
        $0.title == "长江雨课堂" && ["com.tencent.xinWeChat","com.tencent.flue.WeApp"].contains($0.owningApplication?.bundleIdentifier ?? "")
    }
    guard windows.count == 1, let window = windows.first else { throw Problem("课堂窗口数量为 \(windows.count)，等待唯一的长江雨课堂窗口") }
    guard !requireFullSize || (window.frame.width >= 280 && window.frame.height >= 350) else { throw Problem("课堂窗口已缩小，请恢复为正常大小") }
    return window
}

@available(macOS 14.0, *)
func capture(_ window: SCWindow) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width * 2)
    config.height = Int(window.frame.height * 2)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

func loadImage(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Problem("无法读取图片") }
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
            guard let mode = args.first, ["inspect","check","watch","frame","act","focus"].contains(mode) else { throw Problem("用法: rainwatch inspect|check [课程名] [窗口图片] 或 rainwatch watch [课程名]") }
            if mode == "frame" || mode == "act" || mode == "focus" {
                try await interact(args)
                return
            }
            let course = args.count > 1 ? args[1] : "人工智能精通I"
            var previous: String?
            var lastEvent = Date.distantPast
            repeat {
                do {
                    let image: CGImage
                    if args.count == 3 && mode != "watch" { image = try loadImage(args[2]) }
                    else { image = try await capture(targetWindow()) }
                    if mode == "inspect" { for line in try readText(image) { print(line.text) }; return }
                    let top = CGRect(x: 0, y: 0, width: image.width, height: max(1, image.height/6))
                    guard let header = image.cropping(to: top) else { throw Problem("窗口画面无效") }
                    let labels = try readText(header).map { compact($0.text) }
                    guard labels.contains(compact(course)), labels.contains("习题"), labels.contains("PPT") else {
                        let text = try readText(image).map { compact($0.text) }
                        if text.contains(where: { ["课堂已结束","本次课堂已结束","本次授课已结束","老师已下课"].contains($0) }) {
                            emit("ended")
                            return
                        }
                        throw Problem("未看到指定课程的课堂列表")
                    }
                    let cards = try detect(image, course: course)
                    let state = cards.isEmpty ? "no_match" : "pending"
                    let key = state + cards.map(\.page).joined(separator: ",")
                    if previous != key || (!cards.isEmpty && Date().timeIntervalSince(lastEvent) >= 60) {
                        emit(state, cards)
                        previous = key
                        lastEvent = Date()
                    }
                } catch {
                    if mode != "watch" { throw error }
                    let message = error.localizedDescription
                    if previous != message { emit("unavailable", detail: message); previous = message }
                }
                if mode == "watch" { emit("tick"); try await Task.sleep(for: .seconds(5)) }
            } while mode == "watch"
        } catch { emit("error", detail: error.localizedDescription); exit(1) }
    }
}
