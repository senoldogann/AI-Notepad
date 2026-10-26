import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MCPServerTests {
    // Gerçek stdio döngüsü (borular) ve diskteki toplantı: el sıkışma, araç listesi, arama, toplantı, görevler, hata.
    @Test func stdioServerAnswersMeetingQueries() throws {
        let sessions: URL = try temporaryDirectory()
        let folder: URL = sessions.appending(path: "20261026-100000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: MeetingRecord = MeetingRecord(
            id: "20261026-100000", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: nil, language: .finnish,
            status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [stored("final-0", .others, 1, 0, "Kahvikone on rikki, tilaan uuden.")],
            translations: [:], speakerNames: [1: "Mikko"],
            note: MeetingNote(title: "Ofis işleri", summary: "Kahve makinesi bozuldu.", decisions: [],
                              tasks: [NoteTask(owner: "Senol", description: "Faturayı onayla", dueDate: "Cuma", isMine: true)], glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        try saveMeeting(record: record, directory: folder)

        let requests: [String] = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"kahvikone"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"20261026-100000","include_transcript":true}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_my_tasks","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":"yok"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"bilinmeyen"}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_meetings","arguments":{"limit":1e20}}}"#,
            #"{"jsonrpc":"2.0","id":9}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
        ]
        let input: Pipe = Pipe()
        let output: Pipe = Pipe()
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        runMCPServer(input: input.fileHandleForReading, output: output.fileHandleForWriting, sessionsDirectory: sessions, version: "test")
        try output.fileHandleForWriting.close()
        let lines: [String] = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        // Bildirime yanıt yok: 10 yanıt.
        #expect(lines.count == 10)
        #expect(lines[0].contains(#""protocolVersion":"2025-06-18""#) && lines[0].contains(#""tools":{}"#))
        #expect(["list_meetings", "search_meetings", "get_meeting", "list_my_tasks"].allSatisfy { lines[1].contains($0) })
        #expect(lines[2].contains("Kahvikone") && lines[2].contains("20261026-100000"))
        #expect(lines[3].contains("Ofis işleri") && lines[3].contains("Mikko"))
        #expect(lines[4].contains("Faturayı onayla"))
        #expect(lines[5].contains(#""isError":true"#))
        #expect(lines[6].contains("-32601"))
        #expect(lines[7].contains("Ofis işleri"))
        #expect(lines[8].contains("-32600"))
        #expect(lines[9].contains(#""protocolVersion":"2025-06-18""#))
    }
}
