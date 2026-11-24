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

public func percentString(_ progress: Double) -> String {
    "\(Int(progress * 100))%"
}

public func relativeTime(_ date: Date) -> String {
    compactDuration(seconds: Date().timeIntervalSince(date), belowOneMinute: "now")
}

public func durationString(_ seconds: Double) -> String {
    compactDuration(seconds: seconds, belowOneMinute: "<1m")
}

public func remainingSeconds(_ status: TorrentStatus, metainfo: Metainfo) -> Double? {
    guard !status.isComplete, status.downloadRate > 0 else { return nil }
    let remaining = Double(metainfo.totalLength) * (1 - status.progress)
    guard remaining > 0 else { return nil }
    return remaining / status.downloadRate
}

private func compactDuration(seconds: Double, belowOneMinute: String) -> String {
    let seconds = max(0, Int(seconds))
    if seconds < 60 { return belowOneMinute }
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
