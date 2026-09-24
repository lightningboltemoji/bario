import CoreGraphics
import Foundation
import Testing
@testable import BarioKit

@Suite("Config")
struct ConfigTests {
    func message(_ text: String) -> String {
        do {
            _ = try ConfigLoader.parse(text)
            return "parsed, but should not have"
        } catch {
            return "\(error)"
        }
    }

    @Test("the built-in default config is valid")
    func defaultConfig() throws {
        let config = try ConfigLoader.parse(defaultConfigKDL)
        #expect(config.bars.count == 1)
        let bar = config.bars[0]
        #expect(bar.hole.radius == 40)
        #expect(bar.items.map(\.name) == ["app", "spacer-2", "notch-3", "spacer-4", "clock", "status"])
        #expect(bar.items[0].priority == 10)
        #expect(bar.items[1].sizing.grow == 1)
        #expect(bar.items[2].kind == .notch(.always))
    }

    @Test("the design document's example config loads")
    func designExample() throws {
        let config = try ConfigLoader.parse("""
        bar {
          hole radius=40 feather=0 proximity=80 click="reveal"
          item "app" module="front-app" priority=10 format="{name}"
          item "spaces" module="exec" interval="watch" {
            command "aerospace" "list-workspaces"
          }
          spacer
          notch
          spacer
          item "clock" module="clock" format="EEE d MMM  HH:mm" priority=10
          group "status" {
            item "wifi" module="wifi" format="{icon}"
            item "battery" module="battery" format="{icon} {pct}%" { low 20 }
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

        let bar = config.bars[0]
        #expect(bar.items.map(\.name) == ["app", "spaces", "spacer-3", "notch-4", "spacer-5",
                                          "clock", "status", "weather", "ci"])
        #expect(bar.items[1].interval == .watch)
        #expect(bar.items[1].options["command"]?.arrayValue?.count == 2)
        #expect(bar.items[5].format == "EEE d MMM  HH:mm")

        let status = bar.items[6]
        #expect(status.children.map(\.name) == ["wifi", "battery", "volume"])
        #expect(status.children[1].options["low"]?.intValue == 20)
        #expect(status.children[2].actions.scroll == "adjust")
        #expect(status.children[2].actions.click == "toggle-mute")

        let weather = bar.items[7]
        #expect(weather.interval == .seconds(600))
        #expect(weather.moduleName == "wasm")
        // Module options reach the module untouched, whatever they are.
        #expect(weather.options["config"] == .object(["city": .string("Vancouver"),
                                                      "units": .string("metric")]))
        #expect(weather.options["permissions"]?.stringValue == "net")

        #expect(bar.items[8].hiddenUntilSet)
        #expect(config.renderers.count == 1)
        #expect(config.renderers[0].nodeType == "ring")
        #expect(config.renderers[0].path.hasSuffix("/.config/bario/renderers/ring.wasm"))
        #expect(!config.renderers[0].path.hasPrefix("~"))
    }

    @Test("a display picks the most specific bar that matches it")
    func displayFilters() throws {
        let config = try ConfigLoader.parse("""
        bar { item "a" module="clock" }
        bar display="built-in" { item "b" module="clock" }
        bar display="DELL U2723QE" { item "c" module="clock" }
        """)
        func pick(_ name: String, builtIn: Bool) -> String? {
            let display = DisplayInfo(displayID: 1, name: name, frame: .zero, scale: 2,
                                      stripHeight: 24, isBuiltIn: builtIn)
            return config.bar(for: display)?.items.first?.name
        }
        #expect(pick("Built-in Retina Display", builtIn: true) == "b")
        #expect(pick("DELL U2723QE", builtIn: false) == "c")
        #expect(pick("Some Other Monitor", builtIn: false) == "a")
    }

    @Test("durations")
    func durations() throws {
        #expect(ConfigLoader.parseDuration("500ms") == 0.5)
        #expect(ConfigLoader.parseDuration("2s") == 2)
        #expect(ConfigLoader.parseDuration("10m") == 600)
        #expect(ConfigLoader.parseDuration("1h") == 3600)
        #expect(ConfigLoader.parseDuration("3") == 3)
        #expect(ConfigLoader.parseDuration("soon") == nil)
        let config = try ConfigLoader.parse(#"bar { item "a" module="exec" interval=5 }"#)
        #expect(config.bars[0].items[0].interval == .seconds(5))
    }

    @Test("styling in the config is an error that says where it goes")
    func styling() throws {
        #expect(message("bar { padding 0 8 }").contains("style.css: bar { padding: 0pt 8pt }"))
        #expect(message("bar { gap 6 }").contains("style.css: bar { gap: 6pt }"))
        #expect(message(#"bar { item "a" module="clock" width=40 }"#).contains("#a { width: 40pt }"))
        #expect(message(#"bar { item "a" module="clock" max-width=80 }"#).contains("#a { max-width: 80pt }"))
        #expect(message(#"bar { group "g" gap=2 { item "a" module="clock" } }"#).contains("#g { gap: 2pt }"))
        #expect(message(#"bar { group "g" { gap 2; item "a" module="clock" } }"#).contains("#g { gap: 2pt }"))
    }

    @Test("bar-level notch policy is distinct from the notch marker")
    func notch() throws {
        let config = try ConfigLoader.parse("""
        bar { notch "ignore"
              item "a" module="clock" }
        """)
        #expect(config.bars[0].notch == .ignore)
        #expect(config.bars[0].items.map(\.kind) == [.module("clock")])
    }

    @Test("a notch marker takes \"if-present\" as its mode, not its name")
    func notchMarkerModes() throws {
        let config = try ConfigLoader.parse("""
        bar { notch "ignore"; notch; notch "if-present" }
        """)
        #expect(config.bars[0].notch == .ignore)
        #expect(config.bars[0].items.map(\.kind) == [.notch(.always), .notch(.ifPresent)])
        #expect(config.bars[0].items.map(\.name) == ["notch-1", "notch-2"])
        #expect(message(#"bar { notch "sometimes" }"#).contains("\"if-present\" as a marker"))
    }

    @Test("config errors say what and where")
    func errors() throws {
        #expect(message("").contains("no bar node"))
        #expect(message("baz { }").contains("not a top-level node"))
        #expect(message("bar { item \"a\" }").contains("needs module="))
        #expect(message("bar { sidebar 1 }").contains("not something a bar contains"))
        #expect(message("bar { hole wobble=2 }").contains("hole takes radius"))
        #expect(message("bar { hole click=\"maybe\" }").contains("\"reveal\" or \"none\""))
        #expect(message("bar { align sideways\n item \"a\" module=\"clock\" }").contains("align is one of"))
        #expect(message("bar { item \"a\" module=\"exec\" interval=\"soonish\" }").contains("not a duration"))
        #expect(message("bar { group \"g\" { } }").contains("no items in it"))
        #expect(message("renderer \"ring\"").contains("needs path="))
        // The position is the point of all of this.
        #expect(message("bar {\n  item \"a\"\n}").contains(":2:"))
    }

    @Test("an item's content is written as KDL, node for node like the JSON")
    func content() throws {
        let config = try ConfigLoader.parse("""
        bar {
          item "wave" module="data" {
            content {
              raster width=80 height=20 {
                source surface="wave"
              }
            }
          }
          item "battery" module="text" {
            content {
              row gap=4 align="center" class="status" {
                icon "battery.75percent" class="ico"
                text "73%" id="pct"
                meter value=0.73 width=24
                spacer
                graph width=30 {
                  values 1 4 2
                }
                ring value=0.7
              }
            }
          }
        }
        """)
        let items = config.bars[0].items
        #expect(items[0].content == Node(.raster(RasterNode(width: 80, height: 20,
                                                            source: .object(["surface": .string("wave")])))))
        let row = try #require(items[1].content)
        #expect(row == Node.row(gap: 4, align: .center, [
            .icon("battery.75percent", classes: ["ico"]),
            .text("73%", id: "pct"),
            Node(.meter(Meter(value: 0.73, width: 24))),
            Node(.spacer(Spacer())),
            Node(.graph(Graph(values: [1, 4, 2], width: 30))),
            Node(.custom("ring", .object(["value": .number(0.7)]))),
        ], classes: ["status"]))
        // The same tree as the JSON a push would carry.
        let pushed = try JSONDecoder().decode(Node.self, from: Data("""
        {"raster": {"width": 80, "height": 20, "source": {"surface": "wave"}}}
        """.utf8))
        #expect(items[0].content == pushed)
    }

    @Test("content mistakes are config errors, at the node that has them")
    func contentErrors() throws {
        #expect(message("bar { item \"a\" module=\"text\" { content { text \"a\"; text \"b\" } } }")
                .contains("content holds one node"))
        #expect(message("bar { item \"a\" module=\"text\" { content { meter 0.5 width=10 } } }")
                .contains("not both"))
        #expect(message("bar { item \"a\" module=\"text\" format=\"x\" { content { text \"a\" } } }")
                .contains("both format= and content"))
        #expect(message("bar { group \"g\" { content { text \"a\" }; item \"a\" module=\"text\" } }")
                .contains("only an item has content"))
        let raster = message("""
        bar {
          item "a" module="data" {
            content {
              row {
                text "fine"
                raster height=20
              }
            }
          }
        }
        """)
        #expect(raster.contains("raster needs \"width\" and \"source\""))
        #expect(raster.contains(":6:"), "at the raster, not the row: \(raster)")
    }

    @Test("unknown item properties belong to the module, not to bario")
    func unknownOptions() throws {
        let config = try ConfigLoader.parse(#"bar { item "a" module="weather" city="YVR" units="metric" }"#)
        #expect(config.bars[0].items[0].options["city"]?.stringValue == "YVR")
    }

    @Test("flattened lists every item that owns a state key")
    func flattening() throws {
        let config = try ConfigLoader.parse("""
        bar { group "status" { item "wifi" module="wifi"; item "bat" module="battery" } }
        """)
        #expect(config.bars[0].items[0].flattened.map(\.name) == ["status", "wifi", "bat"])
    }
}
