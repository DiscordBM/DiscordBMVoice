/// A 64-bit unique identifier used throughout Discord's API.
///
/// https://discord.com/developers/docs/reference#snowflakes
public struct Snowflake: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init?(_ string: String) {
        guard let value = UInt64(string) else { return nil }
        self.rawValue = value
    }

    public init(integerLiteral value: UInt64) {
        self.rawValue = value
    }

    public init(stringLiteral value: String) {
        self.rawValue = UInt64(value) ?? 0
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            guard let value = UInt64(str) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid 64-bit integer string for Snowflake: '\(str)'"
                )
            }
            self.rawValue = value
        } else if let intVal = try? container.decode(UInt64.self) {
            self.rawValue = intVal
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Snowflake must be a string or integer"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(self.rawValue))
    }

    public var description: String {
        String(self.rawValue)
    }
}

public typealias GuildID = Snowflake
public typealias ChannelID = Snowflake
public typealias UserID = Snowflake
