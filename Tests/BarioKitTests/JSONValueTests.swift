import Testing
@testable import BarioKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test("integral numbers survive a round trip as integers")
    func integersStayIntegers() throws {
        let v = try JSONValue(parsing: #"{"pct": 43, "load": 0.5}"#)
        #expect(v.jsonText.contains("43"))
        #expect(!v.jsonText.contains("43.0"))
        #expect(v["load"]?.doubleValue == 0.5)
    }

    @Test("dotted paths read through nested objects")
    func paths() throws {
        let v = try JSONValue(parsing: #"{"battery": {"pct": 43, "charging": true}}"#)
        #expect(v.value(at: "battery.pct")?.intValue == 43)
        #expect(v.value(at: "battery.charging")?.boolValue == true)
        #expect(v.value(at: "battery.missing") == nil)
        #expect(v.value(at: "")?.objectValue?.count == 1)
    }

    @Test("merge is deep, and an explicit null deletes")
    func merge() throws {
        let base = try JSONValue(parsing: #"{"battery": {"pct": 43, "charging": false}, "wifi": {"ssid": "x"}}"#)
        let patch = try JSONValue(parsing: #"{"battery": {"pct": 44, "charging": null}}"#)
        let merged = base.merging(patch)
        #expect(merged.value(at: "battery.pct")?.intValue == 44)
        #expect(merged.value(at: "battery.charging") == nil)
        #expect(merged.value(at: "wifi.ssid")?.stringValue == "x")
    }

    @Test("merge at a path creates the intermediate objects")
    func mergeAtPath() throws {
        let merged = JSONValue.object([:]).merging(.number(7), at: "weather.temp")
        #expect(merged.value(at: "weather.temp")?.intValue == 7)
    }

    @Test("arrays replace rather than merge")
    func arraysReplace() throws {
        let base = try JSONValue(parsing: #"{"net": {"history": [1, 2, 3]}}"#)
        let merged = base.merging(try JSONValue(parsing: #"{"net": {"history": [9]}}"#))
        #expect(merged.value(at: "net.history")?.arrayValue?.count == 1)
    }

    @Test("setting replaces a subtree instead of merging it")
    func setting() throws {
        let base = try JSONValue(parsing: #"{"a": {"x": 1, "y": 2}}"#)
        let set = base.setting("a", to: try JSONValue(parsing: #"{"x": 9}"#))
        #expect(set.value(at: "a.y") == nil)
        #expect(set.value(at: "a.x")?.intValue == 9)
    }
}
