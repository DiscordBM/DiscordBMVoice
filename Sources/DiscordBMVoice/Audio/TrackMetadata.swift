import Foundation

/// Audio track metadata including song title, artist, duration, requester, and source links.
public struct TrackMetadata: Sendable, Codable, Equatable, CustomStringConvertible {

    /// Track title.
    public var title: String?

    /// Performing artist or creator.
    public var artist: String?

    /// Album or release name.
    public var album: String?

    /// Total track duration.
    public var duration: Duration?

    /// Duration in seconds, synced with the `duration` property.
    public var durationSeconds: Double? {
        get {
            guard let duration else { return nil }
            let (sec, atto) = duration.components
            return Double(sec) + (Double(atto) * 1e-18)
        }
        set {
            if let newValue {
                let sec = Int64(newValue)
                let atto = Int64((newValue - Double(sec)) * 1e18)
                duration = Duration(secondsComponent: sec, attosecondsComponent: atto)
            } else {
                duration = nil
            }
        }
    }

    /// URL pointing to track cover art or video thumbnail.
    public var thumbnailURL: String?

    /// Original source or streaming URL.
    public var sourceURL: String?

    /// Channel name or uploader.
    public var uploader: String?

    /// Discord user ID of the member who requested or queued the track.
    public var requesterID: Snowflake?

    /// Custom key-value string metadata tags.
    public var custom: [String: String]

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Duration? = nil,
        durationSeconds: Double? = nil,
        thumbnailURL: String? = nil,
        sourceURL: String? = nil,
        uploader: String? = nil,
        requesterID: Snowflake? = nil,
        custom: [String: String] = [:]
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        if let duration {
            self.duration = duration
        } else if let durationSeconds {
            let sec = Int64(durationSeconds)
            let atto = Int64((durationSeconds - Double(sec)) * 1e18)
            self.duration = Duration(secondsComponent: sec, attosecondsComponent: atto)
        } else {
            self.duration = nil
        }
        self.thumbnailURL = thumbnailURL
        self.sourceURL = sourceURL
        self.uploader = uploader
        self.requesterID = requesterID
        self.custom = custom
    }

    public var description: String {
        var parts: [String] = []
        if let title { parts.append("title: \"\(title)\"") }
        if let artist { parts.append("artist: \"\(artist)\"") }
        if let uploader { parts.append("uploader: \"\(uploader)\"") }
        if let durationSeconds { parts.append("duration: \(String(format: "%.1f", durationSeconds))s") }
        if let requesterID { parts.append("requester: \(requesterID)") }
        return "TrackMetadata(\(parts.joined(separator: ", ")))"
    }
}

/// Key protocol for type-safe lookups in `TrackUserData`.
public protocol UserDataKey: Sendable {
    associatedtype Value: Sendable
}

/// Type-safe container for bot-specific contextual state attached to an `AudioTrack`.
public struct TrackUserData: @unchecked Sendable {

    private var typedStorage: [ObjectIdentifier: any Sendable] = [:]
    private var namedStorage: [String: any Sendable] = [:]

    public init() {}

    /// Initializes user data with an initial typed context value.
    public init<T: Sendable>(_ initial: T) {
        self.typedStorage[ObjectIdentifier(T.self)] = initial
    }

    /// Accesses context stored by value type.
    public subscript<T: Sendable>(type: T.Type = T.self) -> T? {
        get {
            typedStorage[ObjectIdentifier(type)] as? T
        }
        set {
            if let newValue {
                typedStorage[ObjectIdentifier(type)] = newValue
            } else {
                typedStorage.removeValue(forKey: ObjectIdentifier(type))
            }
        }
    }

    /// Accesses context stored by `UserDataKey`.
    public subscript<K: UserDataKey>(key: K.Type) -> K.Value? {
        get {
            typedStorage[ObjectIdentifier(key)] as? K.Value
        }
        set {
            if let newValue {
                typedStorage[ObjectIdentifier(key)] = newValue
            } else {
                typedStorage.removeValue(forKey: ObjectIdentifier(key))
            }
        }
    }

    /// Retrieves named context by string key.
    public func get<T: Sendable>(_ key: String, as type: T.Type = T.self) -> T? {
        namedStorage[key] as? T
    }

    /// Stores or removes named context by string key.
    public mutating func set<T: Sendable>(_ value: T?, for key: String) {
        if let value {
            namedStorage[key] = value
        } else {
            namedStorage.removeValue(forKey: key)
        }
    }

    /// True if no typed or named user data has been stored.
    public var isEmpty: Bool {
        typedStorage.isEmpty && namedStorage.isEmpty
    }
}
