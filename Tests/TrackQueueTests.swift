import Foundation
import Testing

@testable import DiscordBMVoice

@Suite("Track Queue Tests")
struct TrackQueueTests {

    @Test("TrackQueue begins playback immediately when empty")
    func queuePlaysImmediatelyWhenEmpty() async {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )

        let queue = await fakeConnection.queue
        #expect(await queue.isEmpty)
        #expect(await queue.count == 0)

        let provider = MemoryOpusFrameProvider(frames: [[1, 2, 3]])
        let track = AudioTrack(provider: provider, title: "Song 1")

        let handle = await queue.add(track)
        #expect(await queue.isEmpty == false)
        #expect(await queue.count == 1)
        #expect(await queue.current?.id == handle.id)
        #expect(await queue.currentTrack?.title == "Song 1")
        #expect(await queue.upcomingTracks.isEmpty)
    }

    @Test("TrackQueue enqueues subsequent tracks")
    func queueEnqueuesSubsequentTracks() async {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )

        let queue = await fakeConnection.queue

        let p1 = MemoryOpusFrameProvider(frames: [[1]])
        let p2 = MemoryOpusFrameProvider(frames: [[2]])
        let p3 = MemoryOpusFrameProvider(frames: [[3]])

        let t1 = AudioTrack(provider: p1, title: "Track 1")
        let t2 = AudioTrack(provider: p2, title: "Track 2")
        let t3 = AudioTrack(provider: p3, title: "Track 3")

        _ = await queue.add(t1)
        _ = await queue.add(t2)
        _ = await queue.add(t3)

        #expect(await queue.count == 3)
        #expect(await queue.currentTrack?.title == "Track 1")
        let upcoming = await queue.upcomingTracks
        #expect(upcoming.count == 2)
        #expect(upcoming[0].title == "Track 2")
        #expect(upcoming[1].title == "Track 3")
    }

    @Test("TrackQueue skip advances immediately to next track")
    func queueSkipAdvances() async {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )

        let queue = await fakeConnection.queue

        let p1 = MemoryOpusFrameProvider(frames: [[1]])
        let p2 = MemoryOpusFrameProvider(frames: [[2]])

        let t1 = AudioTrack(provider: p1, title: "Track 1")
        let t2 = AudioTrack(provider: p2, title: "Track 2")

        _ = await queue.add(t1)
        _ = await queue.add(t2)

        let skipped = await queue.skip()
        #expect(skipped?.title == "Track 1")

        #expect(await queue.count == 1)
        #expect(await queue.currentTrack?.title == "Track 2")
        #expect(await queue.upcomingTracks.isEmpty)
    }

    @Test("TrackQueue clear and dequeue operations")
    func queueClearAndDequeue() async {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )

        let queue = await fakeConnection.queue

        let p1 = MemoryOpusFrameProvider(frames: [[1]])
        let p2 = MemoryOpusFrameProvider(frames: [[2]])
        let p3 = MemoryOpusFrameProvider(frames: [[3]])

        let t1 = AudioTrack(provider: p1, title: "Track 1")
        let t2 = AudioTrack(provider: p2, title: "Track 2")
        let t3 = AudioTrack(provider: p3, title: "Track 3")

        _ = await queue.add(t1)
        _ = await queue.add(t2)
        _ = await queue.add(t3)

        let removed = await queue.dequeue(at: 0)
        #expect(removed?.title == "Track 2")
        #expect(await queue.count == 2)
        #expect(await queue.upcomingTracks.count == 1)
        #expect(await queue.upcomingTracks.first?.title == "Track 3")

        await queue.clear()
        #expect(await queue.count == 1)
        #expect(await queue.upcomingTracks.isEmpty)
        #expect(await queue.currentTrack?.title == "Track 1")

        await queue.stop()
        #expect(await queue.isEmpty)
        #expect(await queue.current == nil)
    }

    @Test("TrackQueue seeking forwards to active track")
    func queueSeeking() async throws {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )

        let queue = await fakeConnection.queue
        let dummyFrames: [[UInt8]] = (0..<10).map { [UInt8($0)] }
        let provider = MemoryOpusFrameProvider(frames: dummyFrames)
        let track = AudioTrack(provider: provider, title: "Seekable Song")

        _ = await queue.add(track)
        #expect(await queue.positionSeconds == 0.0)

        try await queue.seek(to: .milliseconds(80))
        #expect(await queue.positionSeconds == 0.08)

        let f4 = await track.nextFrame()
        #expect(f4 == [4])
    }

    @Test("TrackQueue events carry AudioTrack and TrackHandle with metadata and userData")
    func testQueueEventsWithMetadata() async {
        let fakeConnection = VoiceConnection(
            guildID: 12345,
            userID: 67890,
            sendVoiceStateUpdate: { _ in }
        )
        let queue = await fakeConnection.queue

        let p1 = MemoryOpusFrameProvider(frames: [[1]])
        let meta = TrackMetadata(title: "Queue Song", requesterID: 445566)
        var ud = TrackUserData()
        ud.set("SpecialTrack", for: "tag")

        let track = AudioTrack(provider: p1, metadata: meta, userData: ud)
        let handle = await queue.add(track)

        #expect(await queue.currentTrack?.metadata.title == "Queue Song")
        #expect(await queue.currentTrack?.metadata.requesterID == 445566)
        let tag = await handle.userData.get("tag", as: String.self)
        #expect(tag == "SpecialTrack")
    }
}
