import Foundation
import Testing
@testable import BarioKit

@Suite("Content model")
struct NodeTests {
    func decode(_ json: String) throws -> Node {
        try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    }

    @Test("the design document's battery example decodes")
    func batteryExample() throws {
        let json = """
        {
          "content": { "row": { "gap": 4, "children": [
              { "icon": "battery.75percent", "class": "ico" },
              { "text": "73%", "class": "pct" },
              { "meter": { "value": 0.73, "width": 24 }, "class": "bar" }
          ] } },
          "classes": ["charging"],
          "tooltip": "3:10 remaining",
          "visible": true
        }
        """
        let result = try JSONDecoder().decode(RenderResult.self, from: Data(json.utf8))
        #expect(result.classes == ["charging"])
        #expect(result.tooltip == "3:10 remaining")
        #expect(result.visible)
        guard case .row(let row)? = result.content?.kind else { Issue.record("not a row"); return }
        #expect(row.gap == 4)
        #expect(row.children.count == 3)
        #expect(row.children[0].classes == ["ico"])
        guard case .icon(.symbol(let name)) = row.children[0].kind else { Issue.record("not a symbol"); return }
        #expect(name == "battery.75percent")
        guard case .meter(let meter) = row.children[2].kind else { Issue.record("not a meter"); return }
        #expect(meter.value == 0.73)
        #expect(meter.width == 24)
    }

    @Test("every kind survives a JSON round trip")
    func roundTrip() throws {
        let nodes: [Node] = [
            .text("hi", id: "t", classes: ["a", "b"]),
            .icon("wifi"),
            Node(.icon(.file("/tmp/x.png"))),
            Node(.meter(Meter(value: 0.5, width: 24))),
            Node(.graph(Graph(values: [1, 2, 3], width: 40, max: 10))),
            .row(gap: 4, align: .center, [.text("a"), .spacer(grow: 1)]),
            .column([.text("a")]),
            .spacer(),
            Node(.canvas(CanvasNode(width: 28, ops: [.object(["fill": .string("red")])]))),
            Node(.raster(RasterNode(width: 20, source: .string("/tmp/shm")))),
            Node(.custom("ring", .object(["value": .number(0.7)]))),
        ]
        for node in nodes {
            let data = try JSONEncoder().encode(node)
            let back = try JSONDecoder().decode(Node.self, from: data)
            #expect(back == node, "round trip changed \(node.typeName): \(String(decoding: data, as: UTF8.self))")
        }
    }

    @Test("shorthands mean what the longhand means")
    func shorthands() throws {
        #expect(try decode(#"{"text": {"value": "hi"}}"#) == .text("hi"))
        #expect(try decode(#"{"icon": {"symbol": "wifi"}}"#) == .icon("wifi"))
        #expect(try decode(#"{"icon": "~/x.png"}"#) == Node(.icon(.file("~/x.png"))))
        #expect(try decode(#"{"meter": 0.5}"#) == Node(.meter(Meter(value: 0.5))))
        #expect(try decode(#"{"graph": [1, 2]}"#) == Node(.graph(Graph(values: [1, 2]))))
        #expect(try decode(#"{"row": [{"text": "a"}]}"#) == .row([.text("a")]))
        #expect(try decode(#"{"spacer": null}"#) == .spacer())
        #expect(try decode(#"{"spacer": 2}"#) == .spacer(grow: 2))
        #expect(try decode(#"{"text": "a", "class": "x y"}"#) == .text("a", classes: ["x", "y"]))
    }

    @Test("an unregistered node type is data, not an error")
    func customNodes() throws {
        let node = try decode(#"{"ring": {"value": 0.7}, "id": "cpu"}"#)
        #expect(node.typeName == "ring")
        #expect(node.id == "cpu")
        guard case .custom(_, let payload) = node.kind else { Issue.record("not custom"); return }
        #expect(payload["value"]?.doubleValue == 0.7)
    }

    @Test("malformed nodes are rejected with a reason")
    func errors() throws {
        func message(_ json: String) -> String {
            do {
                _ = try decode(json)
                return "decoded, but should not have"
            } catch {
                return "\(error)"
            }
        }
        #expect(message(#"{"class": "x"}"#).contains("kind key"))
        #expect(message(#"{"text": "a", "icon": "b"}"#).contains("exactly one kind key"))
        #expect(message(#"{"text": ["a"]}"#).contains("text takes a string"))
        #expect(message(#"{"meter": {}}"#).contains("numeric"))
        #expect(message(#"{"graph": {}}"#).contains("values"))
        #expect(message(#"{"canvas": {"width": 4}}"#).contains("ops"))
        #expect(message(#"{"raster": {"width": 4}}"#).contains("source"))
        #expect(message(#"{"row": {"align": "sideways"}}"#).contains("align is one of"))
    }

    @Test("visible defaults to true and is omitted when it is")
    func visibility() throws {
        let result = try JSONDecoder().decode(RenderResult.self, from: Data("{}".utf8))
        #expect(result.visible)
        #expect(result.content == nil)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!text.contains("visible"))
    }
}
