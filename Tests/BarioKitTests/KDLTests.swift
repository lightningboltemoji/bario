import Testing
@testable import BarioKit

@Suite("KDL")
struct KDLTests {
    func one(_ text: String) throws -> KDLNode {
        let nodes = try KDL.parse(text)
        #expect(nodes.count == 1)
        return nodes[0]
    }

    func message(_ text: String) -> String {
        do {
            _ = try KDL.parse(text)
            return "parsed, but should not have"
        } catch {
            return "\(error)"
        }
    }

    @Test("nodes take arguments, properties and children")
    func shape() throws {
        let node = try one("""
        item "battery" module="battery" priority=10 {
          low 20
          command "a" "b"
        }
        """)
        #expect(node.name == "item")
        #expect(node.arguments.map(\.value) == [.string("battery")])
        #expect(node.property("module")?.value == .string("battery"))
        #expect(node.property("priority")?.value == .number(10))
        #expect(node.children.count == 2)
        #expect(node.child(named: "low")?.arguments.first?.value == .number(20))
        #expect(node.child(named: "command")?.arguments.map(\.value) == [.string("a"), .string("b")])
    }

    @Test("semicolons and newlines both end a node")
    func terminators() throws {
        let nodes = try KDL.parse("a 1; b 2\nc 3")
        #expect(nodes.map(\.name) == ["a", "b", "c"])
    }

    @Test("values: numbers in four bases, strings, keywords")
    func values() throws {
        let node = try one(#"v 1 -2.5 1e3 0xff 0o17 0b1010 1_000 "s" #true #false #null #inf #nan true false null"#)
        let got = node.arguments.map(\.value)
        #expect(got[0] == .number(1))
        #expect(got[1] == .number(-2.5))
        #expect(got[2] == .number(1000))
        #expect(got[3] == .number(255))
        #expect(got[4] == .number(15))
        #expect(got[5] == .number(10))
        #expect(got[6] == .number(1000))
        #expect(got[7] == .string("s"))
        #expect(got[8] == .bool(true))
        #expect(got[9] == .bool(false))
        #expect(got[10] == .null)
        #expect(got[11].doubleValue == .infinity)
        #expect(got[12].doubleValue?.isNaN == true)
        // The documented deviation: bare keywords keep their KDL 1.0 meaning.
        #expect(got[13] == .bool(true))
        #expect(got[14] == .bool(false))
        #expect(got[15] == .null)
    }

    @Test("a bare word is a string, as in KDL 2.0")
    func bareWordsAreStrings() throws {
        #expect(try one("align center").arguments.first?.value == .string("center"))
        #expect(try one("module front-app").arguments.first?.value == .string("front-app"))
        // Braces still open a children block, so a format string is quoted.
        #expect(try one(#"format "{icon} {pct}%""#).arguments.first?.value == .string("{icon} {pct}%"))
    }

    @Test("strings: escapes, raw, and multi-line dedenting")
    func strings() throws {
        #expect(try one(#"v "a\nb\t\u{1F4A1}\"""#).arguments[0].value == .string("a\nb\t💡\""))
        #expect(try one(##"v #"a\nb"#"##).arguments[0].value == .string(#"a\nb"#))
        #expect(try one(#"v r"a\nb""#).arguments[0].value == .string(#"a\nb"#))
        let multi = try one("""
        v \"\"\"
            one
              two
            \"\"\"
        """)
        #expect(multi.arguments[0].value == .string("one\n  two"))
    }

    @Test("comments: line, nested block, and slashdash")
    func comments() throws {
        let nodes = try KDL.parse("""
        // gone
        a 1 /* and /* nested */ still */ 2
        /-b 3
        c /-4 5 /-key="v" other="k"
        d /-{ inner 1 }
        """)
        #expect(nodes.map(\.name) == ["a", "c", "d"])
        #expect(nodes[0].arguments.map(\.value) == [.number(1), .number(2)])
        #expect(nodes[1].arguments.map(\.value) == [.number(5)])
        #expect(nodes[1].property("key") == nil)
        #expect(nodes[1].property("other")?.value == .string("k"))
        #expect(nodes[2].children.isEmpty)
    }

    @Test("a backslash continues a node onto the next line")
    func continuation() throws {
        let node = try one("""
        item "a" \\
             module="clock"
        """)
        #expect(node.property("module")?.value == .string("clock"))
    }

    @Test("type annotations parse and are carried")
    func annotations() throws {
        let node = try one("(bar)item (u8)5")
        #expect(node.typeAnnotation == "bar")
        #expect(node.arguments[0].value == .number(5))
    }

    @Test("errors carry the line and column")
    func errors() throws {
        #expect(message("a 1\nb {\n").contains("opened at 2:3"))
        #expect(message("a 1\nb {\n").contains("expected }"))
        #expect(message("a \"unterminated").contains("unterminated string"))
        #expect(message("a /* nope").contains("unterminated /* comment"))
        #expect(message("a #wat").contains("unknown keyword"))
        #expect(message("a = 1").contains("found '='"))
        #expect(message("a key=").contains("no value"))
        #expect(message("}").contains("unexpected"))
    }

    @Test("the JSON mapping is the one modules receive")
    func jsonMapping() throws {
        #expect(try one("low 20").json == .number(20))
        #expect(try one(#"permissions "net" "exec""#).json == .array([.string("net"), .string("exec")]))
        #expect(try one("flag").json == .object([:]))
        #expect(try one(#"config city="Vancouver" units="metric""#).json
                == .object(["city": .string("Vancouver"), "units": .string("metric")]))

        let item = try one("""
        item "weather" module="wasm" {
          permissions "net"
          config city="Vancouver"
        }
        """)
        #expect(item.json == .object([
            "args": .array([.string("weather")]),
            "module": .string("wasm"),
            "permissions": .string("net"),
            "config": .object(["city": .string("Vancouver")]),
        ]))
    }

    @Test("repeated children collect into an array")
    func repeatedChildren() throws {
        let node = try one("group x=1 { item \"a\"; item \"b\" }")
        #expect(node.json["item"]?.arrayValue?.count == 2)
    }

    @Test("the design document's example config parses")
    func designExample() throws {
        let nodes = try KDL.parse("""
        // ~/.config/bario/config.kdl
        bar {
          padding 0 8
          gap 6
          hole radius=40 feather=0 proximity=80 click="reveal"

          item "app" module="front-app" priority=10 format="{name}"
          item "spaces" module="exec" interval="watch" {
            command "aerospace" "list-workspaces" "--monitor" "focused" "--format" "%{workspace}"
          }
          spacer
          notch
          spacer
          item "clock" module="clock" format="EEE d MMM  HH:mm" priority=10
          group "status" {
            item "wifi" module="wifi" format="{icon}"
            item "battery" module="battery" format="{icon} {pct}%" {
              low 20
            }
            item "volume" module="volume" format="{icon}" on-scroll="adjust" on-click="toggle-mute"
          }
          item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
            permissions "net"
            config city="Vancouver" units="metric"
          }
          item "ci" module="data" format="{icon} {status}" hidden-until-set=true
        }

        renderer "ring" path="~/.config/bario/renderers/ring.wasm"
        """)
        #expect(nodes.map(\.name) == ["bar", "renderer"])
        let bar = nodes[0]
        #expect(bar.children.map(\.name) == ["padding", "gap", "hole", "item", "item", "spacer",
                                             "notch", "spacer", "item", "group", "item", "item"])
        #expect(bar.child(named: "padding")?.arguments.map(\.value) == [.number(0), .number(8)])
        #expect(bar.children(named: "group").first?.children.count == 3)
        #expect(bar.children(named: "item").last?.property("hidden-until-set")?.value == .bool(true))
        #expect(nodes[1].property("path")?.value == .string("~/.config/bario/renderers/ring.wasm"))
    }
}
