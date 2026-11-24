import Foundation
import TorrentCore

public func byteString(_ bytes: Double) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
    return "\(Int(bytes)) B"
}

public func byteRateString(_ bytesPerSecond: Double) -> String {
    "\(byteString(bytesPerSecond))/s"
}

public func relativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(months / 12)y"
}

public func remainingSeconds(_ status: TorrentStatus, metainfo: Metainfo) -> Double? {
    guard !status.isComplete, status.downloadRate > 0 else { return nil }
    let total = metainfo.files.reduce(Int64(0)) { $0 + Int64($1.length) }
    let remaining = Double(total) * (1 - status.progress)
    guard remaining > 0 else { return nil }
    return remaining / status.downloadRate
}

public func durationString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "<1m" }
    let minutes = s / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    let months = days / 30
    if months < 12 { return "\(months)mo" }
    return "\(months / 12)y"
}
