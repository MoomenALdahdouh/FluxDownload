import XCTest
import FluxDownloadCore
@testable import FluxDownloadMedia

final class MediaParserTests: XCTestCase {
    func testParsesHLSVariants() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720.m3u8
        """
        let group = try HLSParser.parse(text, base: URL(string: "https://cdn.example/master.m3u8")!)
        XCTAssertEqual(group.representations.count, 2)
        XCTAssertTrue(group.representations.contains(where: { $0.height == 720 }))
        XCTAssertFalse(group.isProtected)
    }

    func testRejectsProtectedHLS() throws {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
        720.m3u8
        """
        let group = try HLSParser.parse(text, base: URL(string: "https://cdn.example/master.m3u8")!)
        XCTAssertTrue(group.isProtected)
        XCTAssertTrue(group.visibleRepresentations.isEmpty)
    }

    func testParsesDASH() throws {
        let xml = """
        <MPD>
          <Representation id="1" bandwidth="800000" width="1280" height="720" codecs="avc1" mimeType="video/mp4">
            <BaseURL>video.mp4</BaseURL>
          </Representation>
        </MPD>
        """
        let group = try DASHParser.parse(xml, base: URL(string: "https://cdn.example/manifest.mpd")!)
        XCTAssertEqual(group.representations.first?.height, 720)
    }

    func testRejectsProtectedDASH() {
        let xml = """
        <MPD>
          <ContentProtection schemeIdUri="urn:mpeg:cenc:2013"/>
          <Representation id="1" bandwidth="800000" width="1280" height="720" mimeType="video/mp4"></Representation>
        </MPD>
        """
        XCTAssertThrowsError(try DASHParser.parse(xml, base: URL(string: "https://cdn.example/manifest.mpd")!))
    }

    func testDirectMediaURLs() {
        let group = MediaDetector.group(from: [
            URL(string: "https://cdn.example/a.mp4")!,
            URL(string: "https://cdn.example/b.mp3")!
        ])
        XCTAssertEqual(group.representations.count, 2)
    }
}
