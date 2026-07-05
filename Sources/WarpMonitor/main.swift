import AppKit
import Foundation

// MARK: - Models

struct WarpStatus {
    var warp: String
    var sr: String
    var colo: String
    var timestamp: Date

    var coloOK: Bool { colo == "NRT" }
    var warpOK: Bool { warp == "Connected" }
    var srOff: Bool { sr == "Disconnected" }
    var healthy: Bool { warpOK && coloOK && srOff }

    enum Level: Int {
        case healthy, wrongColo, srStillOn, warpOff, unknown
    }
    var level: Level {
        if warp == "unknown" && colo == "unknown" { return .unknown }
        if !warpOK { return .warpOff }
        if !coloOK { return .wrongColo }
        if !srOff { return .srStillOn }
        return .healthy
    }
    var levelText: String {
        switch level {
        case .healthy:   return "Connected - NRT"
        case .wrongColo: return "Wrong colo (\(colo))"
        case .srStillOn: return "NRT ok - SR still on"
        case .warpOff:   return "WARP disconnected"
        case .unknown:   return "Checking..."
        }
    }
    var levelColor: NSColor {
        switch level {
        case .healthy:   return .systemGreen
        case .wrongColo: return .systemOrange
        case .srStillOn: return .systemYellow
        case .warpOff:   return .systemRed
        case .unknown:   return .systemGray
        }
    }
}

struct TrafficStats {
    var bytesSent: UInt64?
    var bytesReceived: UInt64?
    var uploadBps: Double?
    var downloadBps: Double?
    var latencyMs: Int?
    var timestamp: Date?

    static func empty(at timestamp: Date = Date()) -> TrafficStats {
        TrafficStats(bytesSent: nil,
                     bytesReceived: nil,
                     uploadBps: nil,
                     downloadBps: nil,
                     latencyMs: nil,
                     timestamp: timestamp)
    }

    var totalText: String {
        guard let bytesSent, let bytesReceived else { return "--" }
        return "↑\(Self.formatBytes(bytesSent))  ↓\(Self.formatBytes(bytesReceived))"
    }

    var rateText: String {
        guard let uploadBps, let downloadBps else { return "--" }
        return "↑\(Self.formatRate(uploadBps))  ↓\(Self.formatRate(downloadBps))"
    }

    var latencyText: String {
        guard let latencyMs else { return "--" }
        return "\(latencyMs) ms"
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        let safeValue = max(0, bytesPerSecond)
        return "\(formatBytes(UInt64(safeValue.rounded())))/s"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        if value < 10 {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
        return String(format: "%.0f %@", value, units[unitIndex])
    }
}

// MARK: - Shell

enum Shell {
    static func run(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Daemon

final class WarpDaemon {
    enum Tag {
        case info, action, success, warn, fail
        var color: NSColor {
            switch self {
            case .info:    return .secondaryLabelColor
            case .action:  return .systemBlue
            case .success: return .systemGreen
            case .warn:    return .systemOrange
            case .fail:    return .systemRed
            }
        }
    }

    private(set) var status = WarpStatus(warp: "unknown", sr: "unknown", colo: "unknown", timestamp: Date())
    private(set) var traffic = TrafficStats.empty()
    private(set) var logEntries: [(Date, String, Tag)] = []
    private(set) var recovering = false

    var autoRecover = true
    private var statusObservers: [() -> Void] = []
    private var trafficObservers: [() -> Void] = []
    private var logObservers: [() -> Void] = []
    private var recoverObservers: [() -> Void] = []
    func onStatusChange(_ f: @escaping () -> Void) { statusObservers.append(f) }
    func onTrafficChange(_ f: @escaping () -> Void) { trafficObservers.append(f) }
    func onLogChange(_ f: @escaping () -> Void) { logObservers.append(f) }
    func onRecoverStateChange(_ f: @escaping () -> Void) { recoverObservers.append(f) }
    private func notifyStatus() { statusObservers.forEach { $0() } }
    private func notifyTraffic() { trafficObservers.forEach { $0() } }
    private func notifyLog() { logObservers.forEach { $0() } }
    private func notifyRecover() { recoverObservers.forEach { $0() } }

    private let interval: TimeInterval = 45
    private let trafficInterval: TimeInterval = 3
    private var timer: Timer?
    private var trafficTimer: Timer?
    private var previousTraffic: TrafficStats?
    private let queue = DispatchQueue(label: "warp.daemon", qos: .utility)

    func start() {
        log("WARP Monitor started - interval \(Int(interval))s - target NRT", tag: .info)
        pollAsync()
        pollTrafficAsync()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollAsync()
        }
        trafficTimer = Timer.scheduledTimer(withTimeInterval: trafficInterval, repeats: true) { [weak self] _ in
            self?.pollTrafficAsync()
        }
    }

    func log(_ text: String, tag: Tag = .info) {
        DispatchQueue.main.async {
            self.logEntries.append((Date(), text, tag))
            if self.logEntries.count > 500 { self.logEntries.removeFirst(self.logEntries.count - 500) }
            self.notifyLog()
        }
    }

    func clearLog() {
        logEntries.removeAll()
        notifyLog()
    }

    func pollAsync() {
        queue.async { [weak self] in self?.poll() }
    }

    func pollTrafficAsync() {
        queue.async { [weak self] in self?.pollTraffic() }
    }

    func requestRecover() {
        guard !recovering else { return }
        recovering = true
        notifyRecover()
        queue.async { [weak self] in
            self?.runRecover()
            DispatchQueue.main.async {
                self?.recovering = false
                self?.notifyRecover()
            }
        }
    }

    // MARK: probes

    private func probeWarp() -> String {
        let s = Shell.run("warp-cli status 2>&1 | head -1 | grep -oE 'Connected|Connecting|Disconnecting|Disconnected'")
        return s.isEmpty ? "unknown" : s
    }
    private func probeSR() -> String {
        let raw = Shell.run("scutil --nc list 2>/dev/null | grep -i shadow | head -1")
        if raw.contains("Connected") && !raw.contains("Disconnected") { return "Connected" }
        if raw.contains("Disconnected") { return "Disconnected" }
        return "unknown"
    }
    private func probeColo() -> String {
        let s = Shell.run("curl -s --max-time 8 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}'")
        return s.isEmpty ? "unknown" : s
    }

    private func probeTraffic() -> TrafficStats {
        let now = Date()
        let raw = Shell.run("warp-cli --json tunnel stats")
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bytesSent = uint64Value(json["bytes_sent"]),
              let bytesReceived = uint64Value(json["bytes_received"]) else {
            return .empty(at: now)
        }

        let latency = intValue(json["estimated_latency_ms"])
        var uploadBps: Double?
        var downloadBps: Double?
        if let previousTraffic,
           let previousSent = previousTraffic.bytesSent,
           let previousReceived = previousTraffic.bytesReceived,
           let previousTimestamp = previousTraffic.timestamp {
            let seconds = now.timeIntervalSince(previousTimestamp)
            if seconds > 0 && bytesSent >= previousSent && bytesReceived >= previousReceived {
                uploadBps = Double(bytesSent - previousSent) / seconds
                downloadBps = Double(bytesReceived - previousReceived) / seconds
            }
        }

        return TrafficStats(bytesSent: bytesSent,
                            bytesReceived: bytesReceived,
                            uploadBps: uploadBps,
                            downloadBps: downloadBps,
                            latencyMs: latency,
                            timestamp: now)
    }

    private func uint64Value(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func poll() {
        let new = WarpStatus(warp: probeWarp(), sr: probeSR(), colo: probeColo(), timestamp: Date())
        DispatchQueue.main.async {
            self.status = new
            self.notifyStatus()
            if self.autoRecover && !self.recovering
                && (new.level == .warpOff || new.level == .wrongColo) {
                self.log("unhealthy: \(new.levelText) -> auto recover", tag: .warn)
                self.requestRecover()
            }
        }
    }

    private func pollTraffic() {
        let new = probeTraffic()
        previousTraffic = (new.bytesSent == nil || new.bytesReceived == nil) ? nil : new
        DispatchQueue.main.async {
            self.traffic = new
            self.notifyTraffic()
        }
    }

    // MARK: recovery (runs on daemon queue)

    private enum SRState: String { case on, off }
    private func srSet(_ to: SRState) {
        log("  step: Shadowrocket -> \(to.rawValue)", tag: .action)
        let cur = probeSR()
        let need = (to == .on && cur != "Connected") || (to == .off && cur == "Connected")
        if need { _ = Shell.run("open 'shadowrocket://toggle' 2>/dev/null") }
    }
    /// Poll until SR reaches `expected` state; 1s interval, like wait_sr in warp_to_nrt.sh.
    private func waitSR(_ expected: String, timeout: Int) -> Bool {
        for _ in 0..<timeout {
            if probeSR() == expected { return true }
            sleep(1)
        }
        return false
    }
    /// Poll until WARP reports Connected; 2s interval, like wait_warp in warp_to_nrt.sh.
    private func waitWarp(timeout: Int) -> Bool {
        var t = 0
        while t < timeout {
            if probeWarp() == "Connected" { return true }
            sleep(2); t += 2
        }
        return false
    }
    private func warpConnect() {
        log("  step: warp-cli connect", tag: .action)
        _ = Shell.run("warp-cli connect >/dev/null 2>&1")
    }
    private func warpDisconnect() {
        log("  step: warp-cli disconnect", tag: .action)
        _ = Shell.run("warp-cli disconnect >/dev/null 2>&1")
    }

    /// Strictly mirrors scripts/warp_to_nrt.sh:
    ///   0. reset: SR off (wait), WARP off
    ///   1. SR on (wait Connected) -> sleep 5
    ///   2. warp-cli connect -> sleep 5 -> wait Connected
    ///   3. check colo; != NRT -> full reset
    ///   4. SR off (wait) -> wait WARP auto-reconnect (60s) -> settle 8s
    ///   5. check colo; != NRT -> full reset
    ///   6. SUCCESS
    private func runRecover() {
        let maxAttempts = 20
        log("recover: target SR=off + colo=NRT - max \(maxAttempts) attempts", tag: .action)
        for i in 1...maxAttempts {
            let p = "[\(i)/\(maxAttempts)]"

            log("\(p) [0] reset: SR off, WARP off", tag: .action)
            srSet(.off)
            if !waitSR("Disconnected", timeout: 15) {
                log("\(p) SR still \(probeSR()) after 15s", tag: .warn)
            }
            warpDisconnect(); sleep(3)
            sleep(2)

            log("\(p) [1] SR on -> wait 5s", tag: .action)
            srSet(.on)
            guard waitSR("Connected", timeout: 20) else {
                log("\(p) SR still \(probeSR()) -> full reset", tag: .fail)
                continue
            }
            sleep(5)

            log("\(p) [2] warp-cli connect -> wait 5s", tag: .action)
            warpConnect()
            sleep(5)
            guard waitWarp(timeout: 30) else {
                log("\(p) WARP not Connected after 30s -> full reset", tag: .fail)
                continue
            }

            let colo = probeColo()
            log("\(p) [3] SR=on WARP=Connected colo=\(colo)", tag: .info)
            guard colo == "NRT" else {
                log("\(p) colo=\(colo) != NRT -> full reset", tag: .warn)
                continue
            }

            log("\(p) [4] NRT with SR=on - SR off, wait WARP auto-reconnect", tag: .success)
            srSet(.off)
            if !waitSR("Disconnected", timeout: 20) {
                log("\(p) SR still \(probeSR())", tag: .warn)
            }
            guard waitWarp(timeout: 60) else {
                log("\(p) WARP did not auto-reconnect within 60s -> full reset", tag: .fail)
                continue
            }
            sleep(8)

            let coloOff = probeColo()
            log("\(p) [5] SR=off WARP=Connected colo=\(coloOff)", tag: .info)
            guard coloOff == "NRT" else {
                log("\(p) drifted to \(coloOff) under SR off -> full reset", tag: .warn)
                continue
            }

            log("recover: SUCCESS - SR=off - colo=NRT", tag: .success)
            poll()
            return
        }
        log("recover: FAILED after \(maxAttempts) attempts", tag: .fail)
        poll()
    }
}

// MARK: - Logo

enum Logo {
    /// Classic badge-shield silhouette scaled into `rect` (y-up).
    static func shieldPath(in rect: NSRect) -> NSBezierPath {
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let p = NSBezierPath()
        p.move(to: pt(0.50, 0.96))
        p.curve(to: pt(0.885, 0.845), controlPoint1: pt(0.68, 0.955), controlPoint2: pt(0.81, 0.925))
        p.curve(to: pt(0.865, 0.46), controlPoint1: pt(0.90, 0.72), controlPoint2: pt(0.895, 0.57))
        p.curve(to: pt(0.50, 0.04), controlPoint1: pt(0.83, 0.22), controlPoint2: pt(0.70, 0.075))
        p.curve(to: pt(0.135, 0.46), controlPoint1: pt(0.30, 0.075), controlPoint2: pt(0.17, 0.22))
        p.curve(to: pt(0.115, 0.845), controlPoint1: pt(0.105, 0.57), controlPoint2: pt(0.10, 0.72))
        p.curve(to: pt(0.50, 0.96), controlPoint1: pt(0.19, 0.925), controlPoint2: pt(0.32, 0.955))
        p.close()
        return p
    }

    /// Cloudflare-style cloud silhouette (bumps + flat base) scaled into `rect` (y-up).
    static func cloudPath(in rect: NSRect) -> NSBezierPath {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height,
                   width: w * rect.width, height: h * rect.height)
        }
        let p = NSBezierPath()
        p.windingRule = .nonZero
        p.appendOval(in: r(0.05, 0.10, 0.46, 0.46))
        p.appendOval(in: r(0.30, 0.18, 0.52, 0.72))
        p.appendOval(in: r(0.62, 0.10, 0.34, 0.42))
        p.appendRoundedRect(r(0.09, 0.10, 0.82, 0.32),
                            xRadius: rect.width * 0.08, yRadius: rect.height * 0.08)
        return p
    }

    /// Region inside a shield where the cloud sits (upper-middle, where the shield is widest).
    static func cloudRect(inShield r: NSRect) -> NSRect {
        NSRect(x: r.minX + r.width * 0.17, y: r.minY + r.height * 0.40,
               width: r.width * 0.66, height: r.height * 0.32)
    }

    /// Dock icon: polished macOS Big Sur style. Deep slate rounded-square
    /// background with a subtle top sheen, centered glossy amber shield
    /// (reusing `shieldPath` so the silhouette matches the menu-bar shield)
    /// lit from the top-left, with a drop shadow, inner highlight, lower-edge
    /// darkening, and a thin bright outline for crisp contrast at small sizes.
    /// No cloud glyph.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            // Rounded-square canvas (Big Sur "squircle" proportions).
            let inset = NSRect(x: size * 0.06, y: size * 0.06,
                               width: size * 0.88, height: size * 0.88)
            let bgPath = NSBezierPath(roundedRect: inset,
                                      xRadius: size * 0.205, yRadius: size * 0.205)

            // Deep slate background: slightly lifted top -> near-black bottom.
            NSGradient(colors: [
                NSColor(calibratedRed: 0.235, green: 0.250, blue: 0.330, alpha: 1),
                NSColor(calibratedRed: 0.150, green: 0.160, blue: 0.220, alpha: 1),
                NSColor(calibratedRed: 0.075, green: 0.080, blue: 0.120, alpha: 1),
            ])?.draw(in: bgPath, angle: 90)

            // Subtle glassy top sheen over the background.
            NSGraphicsContext.saveGraphicsState()
            bgPath.addClip()
            NSGradient(colors: [
                NSColor(calibratedWhite: 1, alpha: 0.14),
                NSColor(calibratedWhite: 1, alpha: 0.0),
            ])?.draw(in: bgPath, angle: 90)
            NSGraphicsContext.restoreGraphicsState()

            // Thin dark inner border to seat the squircle.
            NSColor(calibratedWhite: 0, alpha: 0.35).setStroke()
            bgPath.lineWidth = size * 0.004
            bgPath.stroke()

            // Shield silhouette: close to SF Symbols `shield.fill`, with a
            // two-plane top and a smooth tapered lower point.
            let shieldRect = NSRect(x: inset.minX + inset.width * 0.110,
                                    y: inset.minY + inset.height * 0.125,
                                    width: inset.width * 0.78,
                                    height: inset.height * 0.720)
            func spt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: shieldRect.minX + x * shieldRect.width,
                        y: shieldRect.minY + y * shieldRect.height)
            }
            let shield = NSBezierPath()
            shield.move(to: spt(0.50, 0.955))
            shield.line(to: spt(0.175, 0.835))
            shield.curve(to: spt(0.150, 0.490),
                         controlPoint1: spt(0.135, 0.720),
                         controlPoint2: spt(0.125, 0.610))
            shield.curve(to: spt(0.500, 0.055),
                         controlPoint1: spt(0.190, 0.255),
                         controlPoint2: spt(0.320, 0.105))
            shield.curve(to: spt(0.850, 0.490),
                         controlPoint1: spt(0.680, 0.105),
                         controlPoint2: spt(0.810, 0.255))
            shield.curve(to: spt(0.825, 0.835),
                         controlPoint1: spt(0.875, 0.610),
                         controlPoint2: spt(0.865, 0.720))
            shield.line(to: spt(0.50, 0.955))
            shield.close()

            // Drop shadow cast by the shield onto the slate background.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.42)
            shadow.shadowBlurRadius = size * 0.05
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.020)
            shadow.set()
            NSColor(calibratedRed: 0.62, green: 0.22, blue: 0.03, alpha: 1).setFill()
            shield.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Shield body: warm amber, bright at top -> deep burnt orange at bottom.
            let body = NSGradient(colors: [
                NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.46, alpha: 1),
                NSColor(calibratedRed: 0.99, green: 0.64, blue: 0.24, alpha: 1),
                NSColor(calibratedRed: 0.88, green: 0.40, blue: 0.09, alpha: 1),
                NSColor(calibratedRed: 0.66, green: 0.26, blue: 0.04, alpha: 1),
            ])
            body?.draw(in: shield, angle: 90)

            // Interior shading, clipped to the shield.
            NSGraphicsContext.saveGraphicsState()
            shield.addClip()

            // Top-left key light, softened so the top remains shield-like.
            NSGradient(colors: [
                NSColor(calibratedWhite: 1, alpha: 0.38),
                NSColor(calibratedWhite: 1, alpha: 0.00),
            ])?.draw(fromCenter: NSPoint(x: shieldRect.minX + shieldRect.width * 0.32,
                                         y: shieldRect.minY + shieldRect.height * 0.82),
                     radius: size * 0.010,
                     toCenter: NSPoint(x: shieldRect.minX + shieldRect.width * 0.32,
                                       y: shieldRect.minY + shieldRect.height * 0.82),
                     radius: size * 0.21,
                     options: [])

            // Lower-edge darkening for depth and to round the bottom rim.
            let rim = NSBezierPath(ovalIn: NSRect(
                x: shieldRect.minX + shieldRect.width * 0.12,
                y: shieldRect.minY + shieldRect.height * 0.02,
                width: shieldRect.width * 0.76,
                height: shieldRect.height * 0.34))
            NSColor(calibratedRed: 0.42, green: 0.14, blue: 0.02, alpha: 0.34).setFill()
            rim.fill()

            let sideShade = NSBezierPath()
            sideShade.move(to: spt(0.51, 0.94))
            sideShade.line(to: spt(0.825, 0.835))
            sideShade.curve(to: spt(0.50, 0.04),
                            controlPoint1: spt(0.88, 0.56),
                            controlPoint2: spt(0.78, 0.20))
            sideShade.curve(to: spt(0.51, 0.94),
                             controlPoint1: spt(0.58, 0.32),
                             controlPoint2: spt(0.57, 0.68))
            sideShade.close()
            NSColor(calibratedRed: 0.48, green: 0.12, blue: 0.01, alpha: 0.12).setFill()
            sideShade.fill()

            // A small specular glint near the top-left for a glossy read.
            let spec = NSBezierPath(ovalIn: NSRect(
                x: shieldRect.minX + shieldRect.width * 0.18,
                y: shieldRect.minY + shieldRect.height * 0.78,
                width: shieldRect.width * 0.22,
                height: shieldRect.height * 0.095))
            NSColor(calibratedWhite: 1, alpha: 0.34).setFill()
            spec.fill()

            NSGraphicsContext.restoreGraphicsState()

            // Bright inner outline so the shield separates from the slate.
            NSColor(calibratedWhite: 1, alpha: 0.62).setStroke()
            shield.lineWidth = size * 0.007
            shield.stroke()
            return true
        }
    }

    /// Monochrome template menu-bar icon: native SF Symbols shield, like system icons.
    /// shield.fill = WARP connected; shield.slash = disconnected.
    static func menuIcon(filled: Bool) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
        if let sym = NSImage(systemSymbolName: filled ? "shield.fill" : "shield.slash",
                             accessibilityDescription: "WARP status"),
           let img = sym.withSymbolConfiguration(cfg) {
            img.isTemplate = true
            return img
        }
        // Fallback: hand-drawn shield (filled or outline).
        let w: CGFloat = 14, h: CGFloat = 15
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let sRect = rect.insetBy(dx: 1, dy: 0.5)
            NSColor.black.setFill()
            shieldPath(in: sRect).fill()
            if !filled {
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                shieldPath(in: sRect.insetBy(dx: 1.4, dy: 1.4)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}


// MARK: - UI helpers

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
           mono: Bool = false, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                  : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
    }
}

final class StatusDotView: NSView {
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let ring = NSBezierPath(ovalIn: NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d))
        color.withAlphaComponent(0.18).setFill()
        ring.fill()
        let inner = d * 0.45
        let dot = NSBezierPath(ovalIn: NSRect(x: (bounds.width - inner) / 2, y: (bounds.height - inner) / 2, width: inner, height: inner))
        color.setFill()
        dot.fill()
    }
}

// MARK: - Panel

final class PanelViewController: NSViewController {
    let daemon: WarpDaemon

    private let dot = StatusDotView()
    private let stateLabel = label("Checking...", size: 17, weight: .semibold)
    private let coloBig = label("--", size: 34, weight: .bold, mono: true)
    private let warpValue = label("...", size: 12, mono: true)
    private let srValue = label("...", size: 12, mono: true)
    private let coloValue = label("...", size: 12, mono: true)
    private let latencyValue = label("--", size: 12, mono: true)
    private let realtimeValue = label("--", size: 12, mono: true)
    private let cumulativeValue = label("--", size: 12, mono: true)
    private let checkedLabel = label("", size: 10, color: .tertiaryLabelColor)
    private var autoRecoverCheck: NSButton!
    private var recoverBtn: NSButton!
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logDisclosure: NSButton!
    private var clearBtn: NSButton!
    private var logHeightC: NSLayoutConstraint!
    private var logWidthC: NSLayoutConstraint!
    private var logExpanded = false
    private let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    init(daemon: WarpDaemon) {
        self.daemon = daemon
        super.init(nibName: nil, bundle: nil)
        daemon.onStatusChange { [weak self] in self?.refreshStatus() }
        daemon.onTrafficChange { [weak self] in self?.refreshTraffic() }
        daemon.onLogChange { [weak self] in self?.refreshLog() }
        daemon.onRecoverStateChange { [weak self] in self?.refreshRecoverState() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        buildUI()
        refreshStatus()
        refreshTraffic()
        refreshLog()
    }

    private func buildUI() {
        // Header card: dot + state + big colo.
        dot.translatesAutoresizingMaskIntoConstraints = false

        let stateStack = NSStackView(views: [stateLabel, checkedLabel])
        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = 3

        let coloCap = label("colo", size: 10, color: .secondaryLabelColor)
        coloCap.alignment = .center
        let coloStack = NSStackView(views: [coloBig, coloCap])
        coloStack.orientation = .vertical
        coloStack.alignment = .centerX
        coloStack.spacing = 0

        let headerCard = CardView()
        let headerStack = NSStackView(views: [dot, stateStack, NSView(), coloStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(headerStack)
        pin(headerStack, in: headerCard, inset: 14)

        // Traffic card: realtime first, secondary metrics below it.
        realtimeValue.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        latencyValue.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        cumulativeValue.font = .monospacedSystemFont(ofSize: 12, weight: .medium)

        let trafficCard = CardView()
        let liveCap = label("live traffic", size: 10, color: .secondaryLabelColor)
        let liveStack = NSStackView(views: [liveCap, realtimeValue])
        liveStack.orientation = .vertical
        liveStack.alignment = .leading
        liveStack.spacing = 4

        let metricsStack = NSStackView(views: [
            compactMetricRow("Total", cumulativeValue),
            compactMetricRow("Latency", latencyValue),
        ])
        metricsStack.orientation = .vertical
        metricsStack.alignment = .trailing
        metricsStack.spacing = 5

        let trafficStack = NSStackView(views: [liveStack, NSView(), metricsStack])
        trafficStack.orientation = .horizontal
        trafficStack.alignment = .centerY
        trafficStack.spacing = 12
        trafficStack.translatesAutoresizingMaskIntoConstraints = false
        trafficCard.addSubview(trafficStack)
        pin(trafficStack, in: trafficCard, inset: 14)

        // Detail card: WARP / SR / colo rows.
        let detailCard = CardView()
        let detailStack = NSStackView(views: [
            detailRow("WARP", warpValue),
            detailRow("Shadowrocket", srValue),
            detailRow("Colo", coloValue),
        ])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailCard.addSubview(detailStack)
        pin(detailStack, in: detailCard, inset: 14)

        // Controls.
        autoRecoverCheck = NSButton(checkboxWithTitle: "Auto-recover",
                                    target: self, action: #selector(toggleAutoRecover))
        autoRecoverCheck.state = daemon.autoRecover ? .on : .off
        autoRecoverCheck.font = .systemFont(ofSize: 12)

        recoverBtn = NSButton(title: "Recover now", target: self, action: #selector(manualRecover))
        recoverBtn.bezelStyle = .rounded
        recoverBtn.keyEquivalent = "\r"

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(manualRefresh))
        refreshBtn.bezelStyle = .rounded

        let controls = NSStackView(views: [autoRecoverCheck, NSView(), refreshBtn, recoverBtn])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        // Activity log (collapsible, hidden by default).
        logDisclosure = NSButton()
        logDisclosure.setButtonType(.pushOnPushOff)
        logDisclosure.bezelStyle = .disclosure
        logDisclosure.title = ""
        logDisclosure.state = .off
        logDisclosure.target = self
        logDisclosure.action = #selector(toggleLogSection)

        let activityCap = label("Activity", size: 11, color: .secondaryLabelColor)
        clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearBtn.bezelStyle = .inline
        clearBtn.font = .systemFont(ofSize: 10)
        clearBtn.isHidden = true
        let logHeader = NSStackView(views: [logDisclosure, activityCap, NSView(), clearBtn])
        logHeader.orientation = .horizontal
        logHeader.alignment = .centerY
        logHeader.spacing = 4
        logHeader.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = true
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true

        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 8
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.isHidden = true

        // Root.
        let root = NSStackView(views: [headerCard, trafficCard, detailCard, controls, logHeader, logScroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        let rootBottom = root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        rootBottom.priority = .defaultLow
        logHeightC = logScroll.heightAnchor.constraint(equalToConstant: 190)
        logWidthC = logScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            rootBottom,
            dot.widthAnchor.constraint(equalToConstant: 44),
            dot.heightAnchor.constraint(equalToConstant: 44),
            headerCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            trafficCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            detailCard.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            logHeader.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
    }

    private func setLogExpanded(_ expanded: Bool) {
        guard logExpanded != expanded else { return }
        logExpanded = expanded
        logDisclosure.state = expanded ? .on : .off
        clearBtn.isHidden = !expanded
        if expanded {
            logScroll.isHidden = false
            NSLayoutConstraint.activate([logHeightC, logWidthC])
            refreshLog()
        } else {
            NSLayoutConstraint.deactivate([logHeightC, logWidthC])
            logScroll.isHidden = true
        }
        view.layoutSubtreeIfNeeded()
        if let w = view.window {
            var f = w.frame
            let dh = view.fittingSize.height - w.contentRect(forFrameRect: f).height
            f.size.height += dh
            f.origin.y -= dh
            w.setFrame(f, display: true, animate: true)
        }
    }

    private func detailRow(_ name: String, _ value: NSTextField) -> NSStackView {
        let n = label(name, size: 12, color: .secondaryLabelColor)
        let r = NSStackView(views: [n, NSView(), value])
        r.orientation = .horizontal
        r.spacing = 4
        r.translatesAutoresizingMaskIntoConstraints = false
        n.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return r
    }

    private func compactMetricRow(_ name: String, _ value: NSTextField) -> NSStackView {
        let n = label(name, size: 10, color: .secondaryLabelColor)
        let r = NSStackView(views: [n, value])
        r.orientation = .horizontal
        r.alignment = .firstBaseline
        r.spacing = 8
        r.translatesAutoresizingMaskIntoConstraints = false
        n.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        value.alignment = .right
        return r
    }

    private func pin(_ inner: NSView, in outer: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: outer.leadingAnchor, constant: inset),
            inner.trailingAnchor.constraint(equalTo: outer.trailingAnchor, constant: -inset),
            inner.topAnchor.constraint(equalTo: outer.topAnchor, constant: inset),
            inner.bottomAnchor.constraint(equalTo: outer.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: actions

    @objc private func toggleAutoRecover() {
        daemon.autoRecover = autoRecoverCheck.state == .on
        daemon.log("auto-recover \(daemon.autoRecover ? "enabled" : "disabled")", tag: .info)
    }
    @objc private func manualRecover() { daemon.requestRecover() }
    @objc private func manualRefresh() {
        daemon.log("manual refresh", tag: .info)
        daemon.pollAsync()
    }
    @objc private func clearLog() { daemon.clearLog() }
    @objc private func toggleLogSection() { setLogExpanded(logDisclosure.state == .on) }

    // MARK: refresh

    private func refreshStatus() {
        let s = daemon.status
        dot.color = s.levelColor
        stateLabel.stringValue = s.levelText
        stateLabel.textColor = s.levelColor
        coloBig.stringValue = s.colo == "unknown" ? "--" : s.colo
        coloBig.textColor = s.coloOK ? .systemGreen : (s.colo == "unknown" ? .tertiaryLabelColor : .systemOrange)
        warpValue.stringValue = s.warp
        warpValue.textColor = s.warpOK ? .systemGreen : (s.warp == "unknown" ? .secondaryLabelColor : .systemRed)
        srValue.stringValue = s.sr == "Connected" ? "on" : s.srOff ? "off" : "unknown"
        srValue.textColor = s.srOff ? .systemGreen : (s.sr == "Connected" ? .systemOrange : .secondaryLabelColor)
        coloValue.stringValue = s.colo
        coloValue.textColor = s.coloOK ? .systemGreen : .systemOrange
        checkedLabel.stringValue = "Last checked \(timeFmt.string(from: s.timestamp))"
    }

    private func refreshTraffic() {
        let t = daemon.traffic
        latencyValue.stringValue = t.latencyText
        if let latency = t.latencyMs {
            latencyValue.textColor = latency < 150 ? .systemGreen : (latency < 300 ? .systemOrange : .systemRed)
        } else {
            latencyValue.textColor = .secondaryLabelColor
        }
        realtimeValue.stringValue = t.rateText
        realtimeValue.textColor = t.uploadBps == nil ? .secondaryLabelColor : .labelColor
        cumulativeValue.stringValue = t.totalText
        cumulativeValue.textColor = t.bytesSent == nil ? .secondaryLabelColor : .labelColor
    }

    private func refreshRecoverState() {
        recoverBtn.title = daemon.recovering ? "Recovering..." : "Recover now"
        recoverBtn.isEnabled = !daemon.recovering
        autoRecoverCheck.state = daemon.autoRecover ? .on : .off
        if daemon.recovering { setLogExpanded(true) }
        refreshStatus()
    }

    private func refreshLog() {
        guard logExpanded else { return }
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for (ts, text, tag) in daemon.logEntries {
            out.append(NSAttributedString(
                string: "\(timeFmt.string(from: ts))  ",
                attributes: [.font: mono, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(
                string: text + "\n",
                attributes: [.font: mono, .foregroundColor: tag.color]))
        }
        logView.textStorage?.setAttributedString(out)
        logView.scrollToEndOfDocument(nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let daemon = WarpDaemon()
    var window: NSWindow?
    var statusItem: NSStatusItem!
    private var menuStatusLine: NSMenuItem!
    private var menuLatencyLine: NSMenuItem!
    private var menuRealtimeLine: NSMenuItem!
    private var menuCumulativeLine: NSMenuItem!
    private var menuRecover: NSMenuItem!
    private var menuAutoRecover: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = Logo.appIcon()
        buildWindow()
        buildStatusItem()
        daemon.onStatusChange { [weak self] in self?.refreshStatusItem() }
        daemon.onTrafficChange { [weak self] in self?.refreshTrafficItems() }
        daemon.onRecoverStateChange { [weak self] in self?.refreshStatusItem() }
        daemon.start()
    }

    private func buildWindow() {
        let vc = PanelViewController(daemon: daemon)
        let w = NSWindow(contentViewController: vc)
        w.title = "WARP Monitor"
        w.styleMask = [.titled, .closable, .miniaturizable]
        vc.view.layoutSubtreeIfNeeded()
        w.setContentSize(NSSize(width: 380, height: max(vc.view.fittingSize.height, 300)))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Logo.menuIcon(filled: false)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)

        let menu = NSMenu()
        menuStatusLine = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        menuStatusLine.isEnabled = false
        menu.addItem(menuStatusLine)
        menuLatencyLine = NSMenuItem(title: "Latency: --", action: nil, keyEquivalent: "")
        menuLatencyLine.isEnabled = false
        menu.addItem(menuLatencyLine)
        menuRealtimeLine = NSMenuItem(title: "Realtime: --", action: nil, keyEquivalent: "")
        menuRealtimeLine.isEnabled = false
        menu.addItem(menuRealtimeLine)
        menuCumulativeLine = NSMenuItem(title: "Cumulative: --", action: nil, keyEquivalent: "")
        menuCumulativeLine.isEnabled = false
        menu.addItem(menuCumulativeLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open WARP Monitor", action: #selector(openPanel), keyEquivalent: "o"))
        menuRecover = NSMenuItem(title: "Recover Now", action: #selector(menuRecoverNow), keyEquivalent: "r")
        menu.addItem(menuRecover)
        menuAutoRecover = NSMenuItem(title: "Auto-recover", action: #selector(menuToggleAutoRecover), keyEquivalent: "")
        menuAutoRecover.state = daemon.autoRecover ? .on : .off
        menu.addItem(menuAutoRecover)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Status", action: #selector(menuRefresh), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WARP Monitor", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func refreshStatusItem() {
        let s = daemon.status
        statusItem.button?.image = Logo.menuIcon(filled: s.warpOK)
        switch s.level {
        case .wrongColo:  statusItem.button?.title = " \(s.colo)"
        case .srStillOn:  statusItem.button?.title = " SR"
        default:          statusItem.button?.title = ""
        }
        let recovering = daemon.recovering ? " - recovering..." : ""
        menuStatusLine.title = "\(s.levelText)\(recovering)"
        menuRecover.title = daemon.recovering ? "Recovering..." : "Recover Now"
        menuRecover.isEnabled = !daemon.recovering
        menuAutoRecover.state = daemon.autoRecover ? .on : .off
        refreshTrafficItems()
    }

    private func refreshTrafficItems() {
        guard menuLatencyLine != nil else { return }
        let t = daemon.traffic
        menuLatencyLine.title = "Latency: \(t.latencyText)"
        menuRealtimeLine.title = "Realtime: \(t.rateText)"
        menuCumulativeLine.title = "Cumulative: \(t.totalText)"
    }

    // MARK: menu actions

    @objc func openPanel() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func menuRecoverNow() { daemon.requestRecover() }
    @objc private func menuToggleAutoRecover() {
        daemon.autoRecover.toggle()
        daemon.log("auto-recover \(daemon.autoRecover ? "enabled" : "disabled")", tag: .info)
        refreshStatusItem()
    }
    @objc private func menuRefresh() { daemon.pollAsync() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: hide to menu bar on close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openPanel() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum IconExportError: Error, CustomStringConvertible {
    case missingPath(String)
    case bitmapCreationFailed(String)
    case pngCreationFailed(String)

    var description: String {
        switch self {
        case .missingPath(let flag):
            return "Missing path after \(flag)"
        case .bitmapCreationFailed(let path):
            return "Could not create bitmap for \(path)"
        case .pngCreationFailed(let path):
            return "Could not encode PNG for \(path)"
        }
    }
}

enum IconExporter {
    private static let appIconEntries: [(fileName: String, points: Int, scale: Int)] = [
        ("icon_16x16.png", 16, 1),
        ("icon_16x16@2x.png", 16, 2),
        ("icon_32x32.png", 32, 1),
        ("icon_32x32@2x.png", 32, 2),
        ("icon_128x128.png", 128, 1),
        ("icon_128x128@2x.png", 128, 2),
        ("icon_256x256.png", 256, 1),
        ("icon_256x256@2x.png", 256, 2),
        ("icon_512x512.png", 512, 1),
        ("icon_512x512@2x.png", 512, 2),
    ]

    static func exportIconSet(to directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        for entry in appIconEntries {
            let pixels = entry.points * entry.scale
            let image = Logo.appIcon(size: CGFloat(pixels))
            let url = directory.appendingPathComponent(entry.fileName)
            try writePNG(image, to: url, pixels: pixels)
        }
    }

    static func dumpPreviewPNGs(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePNG(Logo.appIcon(), to: directory.appendingPathComponent("warp_appicon.png"), pixels: 256)
        try writePNG(Logo.menuIcon(filled: true),
                     to: directory.appendingPathComponent("warp_menu_filled.png"),
                     pixels: 128,
                     background: NSColor(calibratedWhite: 0.93, alpha: 1))
        try writePNG(Logo.menuIcon(filled: false),
                     to: directory.appendingPathComponent("warp_menu_hollow.png"),
                     pixels: 128,
                     background: NSColor(calibratedWhite: 0.93, alpha: 1))
    }

    private static func writePNG(_ image: NSImage,
                                 to url: URL,
                                 pixels: Int,
                                 background: NSColor? = nil) throws {
        let height = Int(CGFloat(pixels) * image.size.height / image.size.width)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixels,
                                         pixelsHigh: height,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw IconExportError.bitmapCreationFailed(url.path)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        if let background {
            background.setFill()
            NSRect(x: 0, y: 0, width: pixels, height: height).fill()
        }
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: height),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw IconExportError.pngCreationFailed(url.path)
        }
        try data.write(to: url, options: .atomic)
    }
}

func argumentValue(after flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag) else { return nil }
    let valueIndex = args.index(after: index)
    guard valueIndex < args.endIndex, !args[valueIndex].hasPrefix("--") else { return nil }
    return args[valueIndex]
}

do {
    if CommandLine.arguments.contains("--export-iconset") {
        guard let path = argumentValue(after: "--export-iconset") else {
            throw IconExportError.missingPath("--export-iconset")
        }
        try IconExporter.exportIconSet(to: URL(fileURLWithPath: path))
        exit(0)
    }

    if CommandLine.arguments.contains("--dump-icons") {
        let path = argumentValue(after: "--dump-icons") ?? "/tmp"
        try IconExporter.dumpPreviewPNGs(to: URL(fileURLWithPath: path))
        exit(0)
    }
} catch {
    fputs("WARP Monitor icon export failed: \(error)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
