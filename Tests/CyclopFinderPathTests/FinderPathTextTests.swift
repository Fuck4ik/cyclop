import XCTest
@testable import CyclopFinderPath

final class FinderPathTextTests: XCTestCase {
    func testOnePathPerLine() {
        let urls = [
            URL(fileURLWithPath: "/Users/omasn/one.txt"),
            URL(fileURLWithPath: "/Users/omasn/two.txt"),
        ]
        XCTAssertEqual(
            FinderPathText.lines(for: urls),
            "/Users/omasn/one.txt\n/Users/omasn/two.txt"
        )
    }

    func testKeepsSelectionOrder() {
        let urls = [
            URL(fileURLWithPath: "/b"),
            URL(fileURLWithPath: "/a"),
            URL(fileURLWithPath: "/c"),
        ]
        XCTAssertEqual(FinderPathText.paths(for: urls), ["/b", "/a", "/c"])
    }

    func testEmptySelectionGivesEmptyText() {
        XCTAssertEqual(FinderPathText.lines(for: []), "")
    }

    /// Finder hands the selection over as URLs, which means percent escapes.
    /// This is the whole point of the type: what lands on the pasteboard is a
    /// POSIX path, not the URL it arrived in.
    func testDecodesSpacesAndCyrillic() {
        let url = URL(string: "file:///Users/omasn/%D0%9C%D0%BE%D0%B8%20%D1%84%D0%B0%D0%B9%D0%BB%D1%8B/%D0%B7%D0%B0%D0%BC%D0%B5%D1%82%D0%BA%D0%B0.txt")!
        XCTAssertEqual(
            FinderPathText.paths(for: [url]),
            ["/Users/omasn/Мои файлы/заметка.txt"]
        )
    }

    func testKeepsUnicodeOutsideLatin() {
        let urls = [
            URL(fileURLWithPath: "/Users/omasn/Отчёт за июль.pdf"),
            URL(fileURLWithPath: "/Users/omasn/🎧 музыка/трек #1.mp3"),
            URL(fileURLWithPath: "/Users/omasn/日本語.txt"),
        ]
        XCTAssertEqual(FinderPathText.paths(for: urls), [
            "/Users/omasn/Отчёт за июль.pdf",
            "/Users/omasn/🎧 музыка/трек #1.mp3",
            "/Users/omasn/日本語.txt",
        ])
    }

    func testNoSchemePrefixSurvives() {
        let url = URL(string: "file:///tmp/a%20b.txt")!
        XCTAssertFalse(FinderPathText.lines(for: [url]).contains("file://"))
        XCTAssertFalse(FinderPathText.lines(for: [url]).contains("%20"))
    }

    func testFolderComesWithoutTrailingSlash() {
        let asURL = URL(fileURLWithPath: "/Users/omasn/Документы", isDirectory: true)
        let asString = URL(string: "file:///Users/omasn/%D0%94%D0%BE%D0%BA%D1%83%D0%BC%D0%B5%D0%BD%D1%82%D1%8B/")!
        XCTAssertEqual(FinderPathText.paths(for: [asURL]), ["/Users/omasn/Документы"])
        XCTAssertEqual(FinderPathText.paths(for: [asString]), ["/Users/omasn/Документы"])
    }

    func testRootKeepsItsSlash() {
        XCTAssertEqual(FinderPathText.paths(for: [URL(fileURLWithPath: "/")]), ["/"])
    }

    /// A file and a folder in one selection: both are just paths, one per line.
    func testMixedSelection() {
        let urls = [
            URL(fileURLWithPath: "/Volumes/Диск/фото.jpg"),
            URL(fileURLWithPath: "/Volumes/Диск/Архив", isDirectory: true),
        ]
        XCTAssertEqual(
            FinderPathText.lines(for: urls),
            "/Volumes/Диск/фото.jpg\n/Volumes/Диск/Архив"
        )
    }

    func testSkipsAnythingThatIsNotAFile() {
        let urls = [
            URL(string: "https://example.com/a.txt")!,
            URL(fileURLWithPath: "/tmp/real.txt"),
        ]
        XCTAssertEqual(FinderPathText.paths(for: urls), ["/tmp/real.txt"])
    }
}
