import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Audio Track Tests")
struct TrackTests {

    @Test("Audio track basic playback and frame progression")
    func testAudioTrackPlayback() async {
        let dummyFrames: [[UInt8]] = [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
        ]
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let track = AudioTrack(provider: provider)
        let handle = TrackHandle(track: track)

        #expect(await handle.state == .playing)

        let f1 = await track.nextFrame()
        #expect(f1 == [1, 2, 3])

        let f2 = await track.nextFrame()
        #expect(f2 == [4, 5, 6])

        let f3 = await track.nextFrame()
        #expect(f3 == [7, 8, 9])

        let f4 = await track.nextFrame()
        #expect(f4 == nil)
        #expect(await handle.state == .ended)
    }

    @Test("Track pause and resume behavior")
    func testTrackPauseAndResume() async {
        let dummyFrames: [[UInt8]] = [
            [10, 20],
            [30, 40],
        ]
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let track = AudioTrack(provider: provider)
        let handle = TrackHandle(track: track)

        let f1 = await track.nextFrame()
        #expect(f1 == [10, 20])

        await handle.pause()
        #expect(await handle.state == .paused)

        // When paused, nextFrame returns nil to allow silence frame transmission
        let pausedFrame = await track.nextFrame()
        #expect(pausedFrame == nil)
        #expect(await handle.state == .paused)

        await handle.resume()
        #expect(await handle.state == .playing)

        let f2 = await track.nextFrame()
        #expect(f2 == [30, 40])
    }

    @Test("Track stop permanently halts playback")
    func testTrackStop() async {
        let dummyFrames: [[UInt8]] = [
            [1],
            [2],
            [3],
        ]
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let track = AudioTrack(provider: provider)
        let handle = TrackHandle(track: track)

        _ = await track.nextFrame()
        await handle.stop()

        #expect(await handle.state == .stopped)
        let afterStop = await track.nextFrame()
        #expect(afterStop == nil)
    }

    @Test("Memory provider looping support")
    func testMemoryProviderLooping() async {
        let frames: [[UInt8]] = [[1], [2]]
        let provider = MemoryOpusFrameProvider(frames: frames, isLooping: true)

        #expect(await provider.nextFrame() == [1])
        #expect(await provider.nextFrame() == [2])
        #expect(await provider.nextFrame() == [1])
        #expect(await provider.nextFrame() == [2])
    }

    @Test("TrackHandle looping control")
    func testTrackHandleLooping() async {
        let frames: [[UInt8]] = [[10], [20]]
        let provider = MemoryOpusFrameProvider(frames: frames)
        let track = AudioTrack(provider: provider)
        let handle = TrackHandle(track: track)

        #expect(await !handle.isLooping)
        await handle.setLooping(true)
        #expect(await handle.isLooping)

        #expect(await track.nextFrame() == [10])
        #expect(await track.nextFrame() == [20])
        #expect(await track.nextFrame() == [10])
    }

    @Test("Audio track seeking updates position and skips frames")
    func testTrackSeeking() async throws {
        let dummyFrames: [[UInt8]] = (0..<10).map { [UInt8($0)] }
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let track = AudioTrack(provider: provider)
        let handle = TrackHandle(track: track)

        #expect(await handle.positionSeconds == 0.0)
        #expect(await handle.position == .zero)

        let f0 = await track.nextFrame()
        #expect(f0 == [0])
        let f1 = await track.nextFrame()
        #expect(f1 == [1])
        #expect(await handle.positionSeconds >= 0.039)

        try await handle.seek(to: 0.12)
        #expect(await handle.positionSeconds == 0.12)

        let f6 = await track.nextFrame()
        #expect(f6 == [6])

        try await handle.seek(to: .milliseconds(40))
        #expect(await handle.positionSeconds == 0.04)

        let f2 = await track.nextFrame()
        #expect(f2 == [2])
    }

    @Test("Seeking on unseekable provider throws error")
    func testUnseekableThrows() async {
        final class UnseekableStreamer: OpusFrameProvider, @unchecked Sendable {
            func nextFrame() async -> [UInt8]? { [1, 2, 3] }
        }

        let track = AudioTrack(provider: UnseekableStreamer())
        let handle = TrackHandle(track: track)

        do {
            try await handle.seek(to: 5.0)
            Issue.record("Expected AudioSeekError.notSeekable")
        } catch let err as AudioSeekError {
            #expect(err == .notSeekable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("TrackMetadata initialization, sync and JSON Codable roundtrip")
    func testTrackMetadataCodable() throws {
        let meta = TrackMetadata(
            title: "Bohemian Rhapsody",
            artist: "Queen",
            album: "A Night at the Opera",
            duration: .seconds(354),
            thumbnailURL: "https://example.com/cover.jpg",
            sourceURL: "https://example.com/song.mp3",
            uploader: "QueenOfficial",
            requesterID: 987_654_321_012_345_678,
            custom: ["genre": "Rock", "bitrate": "320kbps"]
        )

        #expect(meta.title == "Bohemian Rhapsody")
        #expect(meta.artist == "Queen")
        #expect(meta.album == "A Night at the Opera")
        #expect(meta.duration == .seconds(354))
        #expect(meta.durationSeconds == 354.0)
        #expect(meta.thumbnailURL == "https://example.com/cover.jpg")
        #expect(meta.sourceURL == "https://example.com/song.mp3")
        #expect(meta.uploader == "QueenOfficial")
        #expect(meta.requesterID == 987_654_321_012_345_678)
        #expect(meta.custom["genre"] == "Rock")

        let encoder = JSONEncoder()
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TrackMetadata.self, from: data)

        #expect(decoded == meta)
        #expect(decoded.title == "Bohemian Rhapsody")
        #expect(decoded.durationSeconds == 354.0)
        #expect(decoded.requesterID == 987_654_321_012_345_678)
    }

    @Test("TrackUserData stores and retrieves typed, keyed, and named context")
    func testTrackUserData() async {
        struct SessionContext: Sendable, Equatable {
            let user: String
            let karma: Int
        }

        enum BotChannelKey: UserDataKey {
            typealias Value = Int
        }

        var data = TrackUserData()
        #expect(data.isEmpty)

        data[SessionContext.self] = SessionContext(user: "Alice", karma: 42)
        data[BotChannelKey.self] = 112233
        data.set("https://cdn.example.com/avatar.png", for: "avatar")

        #expect(!data.isEmpty)
        #expect(data[SessionContext.self] == SessionContext(user: "Alice", karma: 42))
        #expect(data[BotChannelKey.self] == 112233)
        #expect(data.get("avatar", as: String.self) == "https://cdn.example.com/avatar.png")

        let provider = MemoryOpusFrameProvider(frames: [[1, 2]])
        let meta = TrackMetadata(title: "Context Song")
        let track = AudioTrack(provider: provider, metadata: meta, userData: data)
        let handle = TrackHandle(track: track)

        let initialUser = await handle.userData[SessionContext.self]
        #expect(initialUser?.user == "Alice")

        await handle.updateUserData { ud in
            ud[SessionContext.self] = SessionContext(user: "Bob", karma: 99)
        }

        let updatedUser = await handle.userData[SessionContext.self]
        #expect(updatedUser?.user == "Bob")
        #expect(updatedUser?.karma == 99)
    }

    @Test("Track lifecycle events carry TrackMetadata")
    func testTrackLifecycleEvents() async {
        let dummyFrames: [[UInt8]] = [[1], [2]]
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let meta = TrackMetadata(
            title: "Lifecycle Song",
            artist: "Tester",
            requesterID: 123_456_789
        )
        let track = AudioTrack(provider: provider, metadata: meta)
        let handle = TrackHandle(track: track)

        _ = await track.nextFrame()
        _ = await track.nextFrame()
        let fNil = await track.nextFrame()
        #expect(fNil == nil)

        var receivedEvents: [TrackEvent] = []
        for await ev in await handle.events {
            receivedEvents.append(ev)
        }

        #expect(receivedEvents.count == 1)
        if case .ended(let endedMeta) = receivedEvents.first {
            #expect(endedMeta.title == "Lifecycle Song")
            #expect(endedMeta.artist == "Tester")
            #expect(endedMeta.requesterID == 123_456_789)
        } else {
            Issue.record("Expected .ended event with metadata")
        }
    }
}
