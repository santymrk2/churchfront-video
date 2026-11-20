import XCTest
import CueATEM

/// The AVMATRIX protocol: frames checked byte for byte against ones confirmed on real
/// switchers (Bitfocus Companion module requests #936 and #1990), and the switcher's
/// state as the rest of the app sees it.
final class AVMatrixTests: XCTestCase {

    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    func testFramesMatchConfirmedOnes() {
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x11, [0x01, 0x00])), "5a 0c 00 00 00 00 03 11 01 00 7b dd")  // auto
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x12, [0x04, 0x00])), "5a 0c 00 00 00 00 03 12 04 00 7f dd")  // program
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0x24, [0x01, 0x00, 0x00, 0x25])), "5a 0e 00 00 00 00 05 24 01 00 00 25 b7 dd")
        XCTAssertEqual(hex(AVMatrixProtocol.frame(0xFE, [0x01])), "5a 0b 00 00 00 00 02 fe 01 66 dd")  // sync
    }

    func testATEMCommandsTranslate() {
        XCTAssertEqual(AVMatrixProtocol.translate("CPgI", [0, 0, 0, 3], ftb: false).map(hex), "5a 0b 00 00 00 00 02 12 03 7c dd")
        XCTAssertEqual(AVMatrixProtocol.translate("CPvI", [0, 0, 0x03, 0xE8], ftb: false)?[8], 5)  // color bars: pattern
        XCTAssertEqual(AVMatrixProtocol.translate("DCut", [0, 0, 0, 0], ftb: false).map { Array($0[7...9]) }, [0x11, 0x02, 0x00])
        XCTAssertEqual(AVMatrixProtocol.translate("FtbA", [0, 0, 0, 0], ftb: true).map { Array($0[8...9]) }, [0x03, 0x00])
        XCTAssertNil(AVMatrixProtocol.translate("CPgI", [1, 0, 0, 3], ftb: false))  // there is no M/E 2
        XCTAssertNil(AVMatrixProtocol.translate("CPgI", [0, 0, 0, 9], ftb: false))  // no input 9
        XCTAssertNil(AVMatrixProtocol.translate("CKOn", [0, 0, 1, 0], ftb: false))
    }

    func testParsesFramesInOneDatagram() {
        let bytes = [0x00] + AVMatrixProtocol.frame(0x12, [2]) + AVMatrixProtocol.frame(0x13, [3])
        let f = AVMatrixProtocol.parse(bytes)
        XCTAssertEqual(f.map(\.command), [0x12, 0x13])
        XCTAssertEqual(f.map(\.data), [[2], [3]])
    }

    func testStateAndTally() {
        var st = AVMatrixStatus()
        st.apply(0x12, [1])
        st.apply(0x13, [5])
        st.apply(0x24, [6, 0, 50, 50])            // PIP 1 shows input 3
        st.apply(0x20, [0, 0, 2, 0, 0, 0])        // PIP 1 on air
        let s = st.atemState()
        XCTAssertEqual(s.program[0], 1)
        XCTAssertEqual(s.preview[0], AVMatrixProtocol.patternSource)
        XCTAssertEqual(s.tally[1], 1)
        XCTAssertEqual(s.tally[3], 1, "a camera in a PIP on air counts as Live")
        XCTAssertEqual(s.tally[2], 0)
        XCTAssertEqual(s.meCount, 1)
        XCTAssertEqual(s.keyerCount, 0)
        XCTAssertEqual(s.auxCount, 0)
    }
}
