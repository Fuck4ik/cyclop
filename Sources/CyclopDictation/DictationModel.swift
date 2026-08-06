import Foundation

/// One recognition model as the worker describes it: what it is called, how
/// big it is, and whether its weights are already on this machine.
public struct DictationModel: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let repo: String
    public let detail: String
    public let sizeMB: Int
    public let ready: Bool
    public let selected: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, repo, detail, ready, selected
        case sizeMB = "size_mb"
    }

    public init(id: String, label: String, repo: String, detail: String, sizeMB: Int, ready: Bool, selected: Bool) {
        self.id = id
        self.label = label
        self.repo = repo
        self.detail = detail
        self.sizeMB = sizeMB
        self.ready = ready
        self.selected = selected
    }

    /// "1.5 GB" or "442 MB" — gigabytes once the number of megabytes stops
    /// being something anyone reads as a size. The unit is separate so the
    /// panel can put a localized word next to a number formatted for the
    /// user's locale, rather than a string built here in English.
    public var size: (value: Double, isGigabytes: Bool) {
        sizeMB >= 1000 ? (Double(sizeMB) / 1024, true) : (Double(sizeMB), false)
    }
}

/// How far a download has got. Carried as megabytes rather than a percentage
/// so the panel can show both the bar and the numbers under it.
public struct DownloadProgress: Equatable, Sendable {
    public let fraction: Double
    public let downloadedMB: Double
    public let totalMB: Double

    public init(fraction: Double, downloadedMB: Double, totalMB: Double) {
        self.fraction = fraction
        self.downloadedMB = downloadedMB
        self.totalMB = totalMB
    }

    /// The worker cannot always say how much there is — an offline dry run
    /// leaves the total at zero. The bar has to know it should keep moving on
    /// its own rather than sit at zero looking stuck.
    public var isDeterminate: Bool { totalMB > 0 }
}
