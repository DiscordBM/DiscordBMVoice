import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Snowflake Tests")
struct SnowflakeTests {

    @Test("Snowflake initialization from integer and string")
    func testSnowflakeInit() {
        let sf1: Snowflake = 123_456_789_012_345_678
        #expect(sf1.rawValue == 123_456_789_012_345_678)
        #expect(sf1.description == "123456789012345678")

        let literal: Snowflake = "123456789012345678"
        #expect(literal.rawValue == 123_456_789_012_345_678)

        let str = "123456789012345678"
        let sf2 = Snowflake(str)
        #expect(sf2?.rawValue == 123_456_789_012_345_678)

        let invalidStr = "not-a-snowflake"
        let invalidSf = Snowflake(invalidStr)
        #expect(invalidSf == nil)
    }

    @Test("Snowflake JSON encoding and decoding")
    func testSnowflakeCodable() throws {
        struct TestContainer: Codable, Equatable {
            var id: Snowflake
        }

        let item = TestContainer(id: 987_654_321_098_765_432)
        let encoded = try JSONEncoder().encode(item)
        let jsonString = String(decoding: encoded, as: UTF8.self)

        // Discord API requires snowflakes to be serialized as JSON strings
        #expect(jsonString.contains("\"id\":\"987654321098765432\""))

        let decoded = try JSONDecoder().decode(TestContainer.self, from: encoded)
        #expect(decoded == item)
    }

    @Test("Snowflake decodes from numeric JSON as well")
    func testSnowflakeNumericDecoding() throws {
        struct TestContainer: Codable, Equatable {
            var id: Snowflake
        }

        let json = "{\"id\": 123456789}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestContainer.self, from: json)
        #expect(decoded.id.rawValue == 123_456_789)
    }
}
