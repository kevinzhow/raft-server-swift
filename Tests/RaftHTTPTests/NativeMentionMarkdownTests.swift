import Foundation
import Testing
@testable import RaftHTTP

private struct NativeMentionSample: Sendable {
    let source: String
    let runs: [String]
    let linkedHandles: [String]

    init(_ source: String, _ runs: [String], _ linkedHandles: [String] = []) {
        self.source = source
        self.runs = runs
        self.linkedHandles = linkedHandles
    }
}

private let nativeMentionSamples: [NativeMentionSample] = [
    .init("", []),
    .init("😀中文 @target", ["😀中文 @target"]),
    .init("before `@hidden` after @visible", ["before ", " after @visible"]),
    .init("😀`@hidden`中文 @visible", ["😀", "中文 @visible"]),
    .init("    @visible", ["    @visible"]),
    .init("[@hidden](url) @visible", [" @visible"]),
    .init("[label](<@target>)", [], ["target"]),
    .init("[label](<&commat;target>)", [], ["target"]),
    .init("[label](<&nbsp;@target&#32;>)", [], ["target"]),
    .init("[label](<@中文>)", [], ["中文"]),
    .init("![label](<@hidden>)", []),
    .init("[![alt](image)](<@outer>)", [], ["outer"]),
    .init("&#64;target", ["&#64;target"]),
    .init("[^id]: @visible", ["[^id]: @visible"]),
    .init("someone@target.invalid", []),
    .init("www.example.invalid/@target", []),
]

@Test func nativeMarkdownPreservesOriginalMentionSurfaces() throws {
    for sample in nativeMentionSamples {
        let result = try MessageMentionMarkdown.parse(sample.source)
        #expect(result.source == sample.source)
        #expect(result.runs == sample.runs, "source=\(sample.source)")
        #expect(result.linkedHandles == sample.linkedHandles, "source=\(sample.source)")
    }
}

@Test func nativeMarkdownParsesConcurrentMessagesWithoutSharingScratch() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for iteration in 0..<64 {
            group.addTask {
                let sample = nativeMentionSamples[iteration % nativeMentionSamples.count]
                let result = try MessageMentionMarkdown.parse(sample.source)
                #expect(result.source == sample.source)
                #expect(result.runs == sample.runs)
                #expect(result.linkedHandles == sample.linkedHandles)
            }
        }
        try await group.waitForAll()
    }
}
