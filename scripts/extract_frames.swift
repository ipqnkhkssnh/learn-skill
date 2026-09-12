// extract_frames.swift — 录屏抽帧工具（macOS / AVFoundation 后端，零第三方依赖）
//
// 用法（一般由 extract_frames.sh 调用，也可单独编译使用）：
//   swiftc -O -parse-as-library extract_frames.swift -o extract_frames_swift
//   ./extract_frames_swift <video> <outdir> [--interval 1] [--max 300] [--width 1280]
//                          [--format jpg|png] [--threshold 2.0] [--min-gap 30]
//                          [--start 0] [--end 0] [--ocr off|on]
//
// 产物：<outdir>/frames/frame_00001.jpg、<outdir>/manifest.json、<outdir>/index.md
//
// 设计要点：
//   * 按固定时间间隔精确取帧（requestedTimeTolerance = zero），时间戳可靠；
//   * 用 8x8 灰度均值哈希（aHash）做感知去重，跳过画面几乎不变的帧，
//     但每 --min-gap 秒至少保留一帧作为时间锚点；
//   * 若采样数超过 --max，自动放大间隔以保证**全程覆盖**而不是截断尾部；
//   * --ocr on 时用 Vision 识别每帧文字，写进 manifest（小字/密集表格的救命稻草）。

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - 参数

struct Options {
    var video: String = ""
    var outDir: String = ""
    var interval: Double = 1.0
    var maxFrames: Int = 300
    var maxWidth: Int = 1280
    var format: String = "jpg"
    var threshold: Double = 2.0
    var minGap: Double = 30.0
    var start: Double = 0.0
    var end: Double = 0.0 // 0 = 到视频结尾
    var ocr: Bool = false
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("extract_frames: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

func parseOptions(_ argv: [String]) -> Options {
    var o = Options()
    var positional: [String] = []
    var i = 1
    func value(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { die("\(flag) 缺少取值") }
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--interval": o.interval = Double(value(a)) ?? o.interval
        case "--max": o.maxFrames = Int(value(a)) ?? o.maxFrames
        case "--width": o.maxWidth = Int(value(a)) ?? o.maxWidth
        case "--format": o.format = value(a).lowercased()
        case "--threshold": o.threshold = Double(value(a)) ?? o.threshold
        case "--min-gap": o.minGap = Double(value(a)) ?? o.minGap
        case "--start": o.start = Double(value(a)) ?? o.start
        case "--end": o.end = Double(value(a)) ?? o.end
        case "--ocr": o.ocr = ["on", "true", "1", "yes"].contains(value(a).lowercased())
        case "-h", "--help":
            print("usage: extract_frames_swift <video> <outdir> [--interval S] [--max N] [--width W] [--format jpg|png] [--threshold F] [--min-gap S] [--start S] [--end S] [--ocr on|off]")
            exit(0)
        default: positional.append(a)
        }
        i += 1
    }
    guard positional.count >= 2 else { die("需要 <video> 与 <outdir> 两个位置参数") }
    o.video = positional[0]
    o.outDir = positional[1]
    if o.interval <= 0 { die("--interval 必须 > 0") }
    if o.maxFrames < 1 { die("--max 必须 >= 1") }
    if o.maxWidth < 64 { die("--width 必须 >= 64") }
    if o.format != "jpg" && o.format != "png" { die("--format 只支持 jpg 或 png") }
    return o
}

// MARK: - 画面签名与差异
//
// 界面录屏的特点：大面积同色背景 + 小面积关键变化（按钮、字段、弹窗、状态色）。
// 因此不用 8x8 aHash（对这种画面几乎饱和、分辨不出变化），改用 32x32 RGB 签名 +
// 逐格平均绝对差（含颜色通道，纯换色的状态变化也能识别）。阈值语义是
// "整幅画面平均每个颜色分量的变化量"，对局部小改动敏感、对编码噪声钝感。

let signatureGrid = 32

func signature(_ image: CGImage) -> [UInt8] {
    let side = signatureGrid
    let bytesPerRow = side * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
    pixels.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Void in
        guard let ctx = CGContext(
            data: buf.baseAddress,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    // 丢掉 alpha 通道，只留 RGB
    var rgb = [UInt8]()
    rgb.reserveCapacity(side * side * 3)
    var i = 0
    while i + 2 < pixels.count {
        rgb.append(pixels[i])
        rgb.append(pixels[i + 1])
        rgb.append(pixels[i + 2])
        i += 4
    }
    return rgb
}

/// 两幅签名之间的平均绝对差（0–255）
func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    var total = 0
    for i in 0..<a.count {
        total += abs(Int(a[i]) - Int(b[i]))
    }
    return Double(total) / Double(a.count)
}

/// 画面内部灰度极差：很小说明是纯色/空白帧
func spread(_ s: [UInt8]) -> Int {
    guard let lo = s.min(), let hi = s.max() else { return 0 }
    return Int(hi) - Int(lo)
}

func fnv1a(_ bytes: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for b in bytes {
        hash ^= UInt64(b)
        hash = hash &* 0x100000001b3
    }
    return hash
}

// MARK: - OCR

let ocrLanguages = ["zh-Hans", "en-US"]

func recognizeText(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ocrLanguages
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        request.recognitionLanguages = ["en-US"]
        try? handler.perform([request])
    }
    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ")
}

// MARK: - 输出

func timeLabel(_ seconds: Double) -> String {
    let total = max(0.0, seconds)
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%02d:%04.1f", m, s)
}

func writeImage(_ image: CGImage, to url: URL, format: String) -> Bool {
    let type: UTType = (format == "png") ? .png : .jpeg
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        return false
    }
    let props: [CFString: Any] = (format == "png") ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.72]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

func jsonEncode(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - 主流程

func runExtraction() -> Never {
let opts = parseOptions(CommandLine.arguments)
let videoURL = URL(fileURLWithPath: (opts.video as NSString).expandingTildeInPath)
let outURL = URL(fileURLWithPath: (opts.outDir as NSString).expandingTildeInPath)

guard FileManager.default.fileExists(atPath: videoURL.path) else { die("视频不存在: \(videoURL.path)") }

let asset = AVURLAsset(url: videoURL)
let duration = CMTimeGetSeconds(asset.duration)
guard duration.isFinite, duration > 0 else { die("无法读取视频时长（文件损坏或不是视频）: \(videoURL.path)") }

let startTime = max(0.0, min(opts.start, duration))
let endTime = (opts.end > 0) ? min(opts.end, duration) : duration
guard endTime > startTime else { die("--end 必须大于 --start") }
let span = endTime - startTime

// 全程覆盖：采样数超过上限时自动放大间隔
var interval = opts.interval
var intervalAdjusted = false
let wanted = Int(ceil(span / interval)) + 1
if wanted > opts.maxFrames {
    interval = span / Double(opts.maxFrames - 1)
    intervalAdjusted = true
}

let framesDir = outURL.appendingPathComponent("frames", isDirectory: true)
try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
// 清掉旧的帧，避免多次运行混在一起
if let old = try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil) {
    for f in old { try? FileManager.default.removeItem(at: f) }
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
if opts.maxWidth > 0 {
    generator.maximumSize = CGSize(width: opts.maxWidth, height: opts.maxWidth)
}

var frames: [[String: Any]] = []
var sampled = 0
var skipped = 0
var lastSignature: [UInt8]? = nil
var lastKeptTime = -Double.greatestFiniteMagnitude
let ext = (opts.format == "png") ? "png" : "jpg"
let startedAt = Date()

var t = startTime
var guardCounter = 0
while t <= endTime + 1e-6 {
    guardCounter += 1
    if guardCounter > 2_000_000 { break } // 防御：异常参数导致的死循环
    sampled += 1

    let cmTime = CMTime(seconds: t, preferredTimescale: 600)
    var actual = CMTime.zero
    guard let image = try? generator.copyCGImage(at: cmTime, actualTime: &actual) else {
        skipped += 1
        t += interval
        continue
    }

    let sig = signature(image)
    let diff = lastSignature.map { meanDifference($0, sig) } ?? 255.0
    let isUniform = spread(sig) < 4
    let changed = diff > opts.threshold
    let anchorDue = (t - lastKeptTime) >= opts.minGap

    // 纯色/空白帧不占额度（除非整段视频一帧都还没有），其余按变化量决定
    var keep = frames.isEmpty || (changed && !isUniform)
    if !keep && anchorDue && !isUniform { keep = true }

    if !keep {
        skipped += 1
        t += interval
        continue
    }

    let index = frames.count + 1
    let name = String(format: "frame_%05d.%@", index, ext)
    let fileURL = framesDir.appendingPathComponent(name)
    guard writeImage(image, to: fileURL, format: opts.format) else {
        FileHandle.standardError.write("extract_frames: 写图失败 \(fileURL.path)\n".data(using: .utf8)!)
        t += interval
        continue
    }

    var entry: [String: Any] = [
        "index": index,
        "file": "frames/" + name,
        "t": (Double(actual.seconds) * 100).rounded() / 100,
        "tLabel": timeLabel(Double(actual.seconds)),
        "width": image.width,
        "height": image.height,
        "sigHash": String(format: "%016llx", fnv1a(sig)),
        "diff": (diff * 10).rounded() / 10,
    ]
    if opts.ocr {
        let text = recognizeText(image)
        if !text.isEmpty { entry["ocr"] = text }
    }
    frames.append(entry)
    lastSignature = sig
    lastKeptTime = t

    t += interval
}

let manifest: [String: Any] = [
    "video": videoURL.path,
    "outDir": outURL.path,
    "backend": "swift-avfoundation",
    "extractedAt": ISO8601DateFormatter().string(from: startedAt),
    "durationSeconds": (duration * 100).rounded() / 100,
    "rangeStart": startTime,
    "rangeEnd": endTime,
    "intervalSeconds": (interval * 1000).rounded() / 1000,
    "intervalAdjusted": intervalAdjusted,
    "requestedIntervalSeconds": opts.interval,
    "maxWidth": opts.maxWidth,
    "dedupeThreshold": opts.threshold,
    "signatureGrid": signatureGrid,
    "minGapSeconds": opts.minGap,
    "ocr": opts.ocr,
    "sampledFrames": sampled,
    "keptFrames": frames.count,
    "skippedFrames": skipped,
    "frames": frames,
]

let manifestURL = outURL.appendingPathComponent("manifest.json")
try? jsonEncode(manifest).write(to: manifestURL, atomically: true, encoding: .utf8)

// index.md —— 给模型看的时间轴索引
var md = "# 抽帧索引 · \(videoURL.lastPathComponent)\n\n"
md += "- 时长: \(String(format: "%.1f", duration))s（本次区间 \(timeLabel(startTime)) → \(timeLabel(endTime))）\n"
md += "- 采样间隔: \(String(format: "%.2f", interval))s\(intervalAdjusted ? "（因 --max 上限自动放大）" : "")\n"
md += "- 采样 \(sampled) 帧 → 去重保留 **\(frames.count)** 帧\n"
if opts.ocr { md += "- OCR: 已开启（每帧文字见 manifest.json 的 ocr 字段）\n" }
md += "\n| # | 时间 | 文件 |" + (opts.ocr ? " OCR 摘要 |" : "") + "\n|---|---|---|" + (opts.ocr ? "---|" : "") + "\n"
for f in frames {
    let idx = f["index"] as? Int ?? 0
    let label = f["tLabel"] as? String ?? ""
    let file = f["file"] as? String ?? ""
    if opts.ocr {
        var text = (f["ocr"] as? String) ?? ""
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        text = text.replacingOccurrences(of: "|", with: "/")
        md += "| \(idx) | \(label) | \(file) | \(text) |\n"
    } else {
        md += "| \(idx) | \(label) | \(file) |\n"
    }
}
try? md.write(to: outURL.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)

FileHandle.standardError.write(
    "extract_frames: \(videoURL.lastPathComponent) → \(frames.count) 帧（采样 \(sampled)）写入 \(outURL.path)\n"
        .data(using: .utf8)!)
print(jsonEncode([
    "ok": true,
    "outDir": outURL.path,
    "frames": frames.count,
    "sampled": sampled,
    "intervalSeconds": (interval * 1000).rounded() / 1000,
    "manifest": manifestURL.path,
]))
exit(0)
}

@main
enum ExtractFramesCLI {
    static func main() {
        runExtraction()
    }
}
