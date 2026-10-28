import Foundation
import Testing
@testable import AINotepadCore

@Suite struct TrackerTargetTests {
    // Linear `list_teams` çıktısı (açıklama metniyle sarılı JSON): adı ve anahtarı olan takımlar sırayla, tekrarsız.
    @Test func linearTeamsAreParsed() throws {
        let text: String = """
        Teams:
        {"teams":[{"id":"t1","name":"Myprojects","key":"MYP"},{"id":"t2","name":"Design","key":"DES"},{"id":"t3","name":"Myprojects","key":"MYP"}]}
        """
        #expect(try parseTrackerTargetNames(text: text, server: "mcp.linear.app") == ["Myprojects", "Design"])
    }

    // Jira projeleri dizi olarak gelebilir; anahtarsız nesneler (ör. kullanıcı) hedef sayılmaz.
    @Test func jiraProjectsIgnoreUnkeyedObjects() throws {
        let text: String = #"[{"name":"Mobile","key":"MOB","lead":{"name":"Aino"}},{"name":"Web","key":"WEB"}]"#
        #expect(try parseTrackerTargetNames(text: text, server: "mcp.atlassian.com") == ["Mobile", "Web"])
    }

    // Atlassian sitelerinden ilkinin bulut kimliği; JSON yoksa açık hata.
    @Test func atlassianCloudIDAndErrors() throws {
        let text: String = #"[{"id":"cloud-1","url":"https://acme.atlassian.net","name":"acme"},{"id":"cloud-2","url":"https://b.atlassian.net"}]"#
        #expect(try parseAtlassianCloudID(text: text, server: "mcp.atlassian.com") == "cloud-1")
        #expect(throws: MCPRemoteError.self) { try parseTrackerTargetNames(text: "takım yok", server: "mcp.linear.app") }
    }
}
