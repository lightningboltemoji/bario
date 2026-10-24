import CoreGraphics
import Foundation
import Testing
@testable import BarioKit

@Suite("SkyLight")
@MainActor
struct SkyLightTests {
    /// The zoom event's payloads as measured on macOS 27.2: Space 2149 (0x865), then 0 or 1.
    func zoom(_ hex: String) -> (space: UInt64, landed: Bool)? {
        var bytes: [UInt8] = []
        var rest = Substring(hex)
        while rest.count >= 2 {
            bytes.append(UInt8(rest.prefix(2), radix: 16)!)
            rest = rest.dropFirst(2)
        }
        return bytes.withUnsafeBytes { SkyLight.zoom($0) }
    }

    @Test("a zoom's event says which Space, and whether the app has landed in it")
    func zoomPayload() throws {
        let starts = try #require(zoom("65080000000000000000000000000000"))
        #expect(starts.space == 2149)
        #expect(!starts.landed)
        let lands = try #require(zoom("65080000000000000100000000000000"))
        #expect(lands.space == 2149)
        #expect(lands.landed)
        #expect(zoom("6508000000000000") == nil, "too short to be one")
    }

    @Test("a full screen Space is found on its display before it is current")
    func zoomDisplay() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "BUILT-IN",
             "Current Space": ["ManagedSpaceID": 1949, "type": 0],
             "Spaces": [["ManagedSpaceID": 1949, "type": 0]]],
            ["Display Identifier": "STUDIO",
             "Current Space": ["ManagedSpaceID": 1, "type": 0],
             "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 2149, "type": 4]]],
        ]
        let uuids: [CGDirectDisplayID: String] = [1: "BUILT-IN", 2: "STUDIO"]
        func matching(_ test: @escaping ([String: Any]) -> Bool, in described: [[String: Any]]) -> Set<CGDirectDisplayID> {
            SkyLight.displays(among: [1, 2], in: described, uuid: { uuids[$0] }, where: test)
        }
        #expect(matching(SkyLight.hasFullscreenSpace(2149), in: displays) == [2])
        #expect(matching(SkyLight.hasFullscreenSpace(1), in: displays).isEmpty, "a desktop is not a full screen app's")
        #expect(matching(SkyLight.hasFullscreenSpace(7), in: displays).isEmpty, "nor is a Space no display has")

        // With "Displays have separate Spaces" off, one set of Spaces is every display's.
        let shared: [[String: Any]] = [
            ["Display Identifier": "Main", "Spaces": [["ManagedSpaceID": 2149, "type": 4]]],
        ]
        #expect(matching(SkyLight.hasFullscreenSpace(2149), in: shared) == [1, 2])
    }
}
