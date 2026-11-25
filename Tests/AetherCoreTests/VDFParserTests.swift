import Testing
@testable import AetherCore

@Suite("VDFParser")
struct VDFParserTests {

    @Test("Modern libraryfolders.vdf")
    func modernLibraryFolders() throws {
        let text = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/me/Library/Application Support/Steam"
        \t\t"apps"
        \t\t{
        \t\t\t"1091500"\t\t"65000000000"
        \t\t}
        \t}
        \t"1"
        \t{
        \t\t"path"\t\t"/Volumes/SSD/SteamLibrary"
        \t}
        }
        """
        let root = try VDFParser.parse(text)
        let folders = try #require(root["libraryfolders"])
        #expect(folders.children.count == 2)
        #expect(folders["0"]?["path"]?.stringValue == "/Users/me/Library/Application Support/Steam")
        #expect(folders["0"]?["apps"]?["1091500"]?.stringValue == "65000000000")
        #expect(folders["1"]?["path"]?.stringValue == "/Volumes/SSD/SteamLibrary")
    }

    @Test("Escapes, comments, conditionals, bare tokens, case-insensitive keys")
    func syntaxEdgeCases() throws {
        let text = #"""
        // header comment
        "AppState"
        {
            "appid"   "70"            // trailing comment
            "name"    "Half-Life \"Classic\""
            "path"    "C:\\Program Files (x86)\\Steam"
            "flag"    "1" [$WIN32]
            bare      token
        }
        """#
        let state = try #require(try VDFParser.parse(text)["appstate"])
        #expect(state["APPID"]?.stringValue == "70")
        #expect(state["name"]?.stringValue == #"Half-Life "Classic""#)
        #expect(state["path"]?.stringValue == #"C:\Program Files (x86)\Steam"#)
        #expect(state["flag"]?.stringValue == "1")
        #expect(state["bare"]?.stringValue == "token")
    }

    @Test("Malformed input throws", arguments: [
        #""a" { "b" "c" "#,      // unclosed block
        #""a" "unterminated"#,   // unterminated string
        "}",                     // stray brace
        #""key""#,               // key with no value
    ])
    func malformed(_ text: String) {
        #expect(throws: VDFError.self) { try VDFParser.parse(text) }
    }
}
