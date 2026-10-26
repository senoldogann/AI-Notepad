import Foundation
import Testing
@testable import AINotepadCore

@Suite struct FolderTests {
    // Kullanılan ve boş kaydedilmiş klasörler tek listede, sayılarıyla; büyük/küçük harf farkı aynı klasör.
    @Test func foldersCombineSavedAndUsed() {
        let base: MeetingRecord = MeetingRecord(
            id: "1", title: "T", startedAt: Date(), endedAt: nil, language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let records: [MeetingRecord] = [base.with(folder: "Proje X"), base.with(folder: "proje x"), base.with(folder: "Ders"), base]
        #expect(meetingFolders(records: records, saved: ["Ekip", "Ders"]) == [
            FolderSummary(name: "Ders", count: 1), FolderSummary(name: "Ekip", count: 0), FolderSummary(name: "Proje X", count: 2),
        ])
        #expect(meetingsInFolder(records: records, folder: "PROJE X").count == 2)
        #expect(meetingsInFolder(records: records, folder: nil).count == 4)
    }
}
