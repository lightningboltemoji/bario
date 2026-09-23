import CoreAudio
import Foundation
import Testing
@testable import BarioKit

@Suite("Module support")
struct ModuleSupportTests {
    @Test("history is a fixed-length rolling window")
    func history() {
        var history = History(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        #expect(history.values == [3, 4, 5])
        #expect(history.peak == 5)
        #expect(history.json == .array([.number(3), .number(4), .number(5)]))
    }

    @Test("byte rates scale to units a format string cannot")
    func bytes() {
        #expect(Humanise.bytes(0, perSecond: true) == "0 B/s")
        #expect(Humanise.bytes(999) == "999 B")
        #expect(Humanise.bytes(1_000) == "1.0 kB")
        #expect(Humanise.bytes(1_234_000, perSecond: true) == "1.2 MB/s")
        #expect(Humanise.bytes(12_340_000) == "12 MB")
        #expect(Humanise.bytes(-5) == "0 B")
    }

    @Test("durations are written the way a battery estimate is read")
    func durations() {
        #expect(Humanise.duration(minutes: 190) == "3:10")
        #expect(Humanise.duration(minutes: 5) == "0:05")
    }

    @Test("the battery icon ladder")
    func batteryIcons() {
        #expect(Symbols.battery(percent: 100, charging: false, plugged: false) == "battery.100percent")
        #expect(Symbols.battery(percent: 70, charging: false, plugged: false) == "battery.75percent")
        #expect(Symbols.battery(percent: 50, charging: false, plugged: false) == "battery.50percent")
        #expect(Symbols.battery(percent: 20, charging: false, plugged: false) == "battery.25percent")
        #expect(Symbols.battery(percent: 5, charging: false, plugged: false) == "battery.0percent")
        #expect(Symbols.battery(percent: 5, charging: true, plugged: true).hasSuffix(".bolt"))
    }

    @Test("the wi-fi bars ladder")
    func wifiBars() {
        #expect(Symbols.wifiBars(rssi: -40) == 3)
        #expect(Symbols.wifiBars(rssi: -60) == 2)
        #expect(Symbols.wifiBars(rssi: -75) == 1)
        #expect(Symbols.wifiBars(rssi: -95) == 0)
        #expect(Symbols.wifi(on: false, rssi: -40) == "wifi.slash")
    }

    @Test("the volume icon ladder")
    func volumeIcons() {
        #expect(Symbols.volume(level: 0, muted: false) == "speaker.slash.fill")
        #expect(Symbols.volume(level: 50, muted: true) == "speaker.slash.fill")
        #expect(Symbols.volume(level: 10, muted: false) == "speaker.wave.1.fill")
        #expect(Symbols.volume(level: 50, muted: false) == "speaker.wave.2.fill")
        #expect(Symbols.volume(level: 90, muted: false) == "speaker.wave.3.fill")
    }

    @Test("headphones show as what they are")
    func headphoneIcons() {
        #expect(Symbols.headphones(name: "Tanner’s AirPods Max", muted: false) == "airpods.max")
        #expect(Symbols.headphones(name: "AirPods Pro", muted: false) == "airpods.pro")
        #expect(Symbols.headphones(name: "Someone's AirPods", muted: false) == "airpods")
        #expect(Symbols.headphones(name: "Beats Studio Pro", muted: false) == "beats.headphones")
        #expect(Symbols.headphones(name: "External Headphones", muted: false) == "headphones")
        #expect(Symbols.headphones(name: "AirPods Max", muted: true) == "headphones.slash")
    }

    @Test("headphones are read from the jack, Bluetooth, or the name")
    func headphoneDetection() {
        let jack = VolumeModule.headphoneSource
        let speakers: UInt32 = 0x6973_706B    // 'ispk'
        #expect(VolumeModule.isHeadphones(name: "External Headphones", transport: .builtIn, dataSource: jack))
        #expect(VolumeModule.isHeadphones(name: "Built-in Output", transport: .builtIn, dataSource: jack),
                "an Intel Mac's jack is a data source on the built-in device")
        #expect(!VolumeModule.isHeadphones(name: "MacBook Pro Speakers", transport: .builtIn, dataSource: speakers))
        #expect(VolumeModule.isHeadphones(name: "WH-1000XM5", transport: .bluetooth, dataSource: nil))
        #expect(!VolumeModule.isHeadphones(name: "Kitchen Speaker", transport: .bluetooth, dataSource: nil,
                                           speakers: ["kitchen"]))
        #expect(VolumeModule.isHeadphones(name: "USB Headset", transport: .usb, dataSource: nil))
        #expect(!VolumeModule.isHeadphones(name: "LG UltraFine", transport: .displayport, dataSource: nil))
        #expect(VolumeModule.Transport(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
    }

    @Test("CPU load is a difference between two samples")
    func cpuDelta() {
        let a = CPUModule.Ticks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUModule.Ticks(user: 140, system: 60, idle: 900, nice: 0)
        let delta = CPUModule.delta(a, b)
        #expect(abs(delta.load - 0.5) < 0.001)
        #expect(abs(delta.user - 0.4) < 0.001)
        #expect(abs(delta.system - 0.1) < 0.001)
        // Two identical samples mean no time passed, not 100% busy.
        #expect(CPUModule.delta(a, a).load == 0)
    }
}

@Suite("Built-in modules")
struct BuiltInModuleTests {
    /// Run a module the way the host does: poll once, merge, render.
    func run(_ name: String, config: JSONValue = .object([:]), format: String? = nil)
        async throws -> (RenderResult, JSONValue) {
        ModuleRegistry.registerBuiltIns()
        let store = StateStore()
        let context = ModuleContext(item: name, config: config, format: format, store: store)
        let module = try ModuleRegistry.make(name, context: context)
        await module.start()
        let poll = await module.poll()
        if let patch = poll.patch { await store.merge(patch, at: name) }
        let result = try await module.render(await store.reader(for: name))
        await module.stop()
        return (result, await store.value(at: name) ?? .null)
    }

    @Test("every built-in is registered and renders something")
    func allOfThem() async throws {
        ModuleRegistry.registerBuiltIns()
        #expect(ModuleRegistry.names.contains("front-app"))
        for name in ["clock", "front-app", "battery", "volume", "wifi", "net", "cpu", "mem"] {
            let (result, state) = try await run(name)
            #expect(result.visible, "\(name) rendered invisible")
            #expect(state.objectValue != nil || name == "clock", "\(name) wrote no state")
        }
    }

    @Test("battery reads this machine and classifies it")
    func battery() async throws {
        let (result, state) = try await run("battery", config: .object(["low": .number(20)]),
                                            format: "{icon} {pct}%")
        guard state["present"]?.boolValue == true else { return }   // a desktop has no battery
        let percent = state["pct"]?.doubleValue ?? -1
        #expect(percent >= 0 && percent <= 100)
        #expect(state["icon"]?.stringValue?.hasPrefix("battery") == true)
        if percent <= 20 { #expect(result.classes.contains("low")) }
        // A still-estimating battery must not render "-1".
        if let remaining = state["time-remaining"]?.intValue { #expect(remaining >= 0) }
    }

    @Test("volume names the output device and says whether it is headphones")
    func volume() async throws {
        let (result, state) = try await run("volume", format: "{icon}")
        guard state["present"]?.boolValue == true else { return }   // no output device at all
        #expect(state["device"]?.stringValue?.isEmpty == false)
        #expect(state["transport"]?.stringValue != nil)
        let headphones = state["headphones"]?.boolValue == true
        #expect(result.classes.contains("headphones") == headphones)
        #expect(state["level-icon"]?.stringValue?.hasPrefix("speaker") == true)
        if !headphones { #expect(state["icon"] == state["level-icon"]) }
    }

    @Test("front-app names the app in front, truncated if asked")
    func frontApp() async throws {
        let (_, state) = try await run("front-app", config: .object(["max-length": .number(4)]),
                                       format: "{name}")
        let name = state["name"]?.stringValue ?? ""
        #expect(name.count <= 4)
    }

    @Test("wi-fi works without Location Services")
    func wifi() async throws {
        let (result, state) = try await run("wifi", format: "{icon}")
        #expect(state["present"] != nil)
        #expect(state["icon"]?.stringValue?.hasPrefix("wifi") == true)
        // No SSID asked for, so no permission asked for and no denial recorded.
        #expect(state["ssid-denied"] == nil)
        #expect(result.content != nil)
    }

    @Test("net counters are non-negative and produce a human rate")
    func net() async throws {
        let (_, state) = try await run("net")
        #expect((state["rx-total"]?.doubleValue ?? -1) >= 0)
        #expect(state["rx-human"]?.stringValue?.hasSuffix("/s") == true)
        #expect(NetModule.counters(interface: "lo0").rx >= 0)
    }

    @Test("memory reads plausibly")
    func memory() async throws {
        let (_, state) = try await run("mem")
        let fraction = state["fraction"]?.doubleValue ?? -1
        #expect(fraction > 0 && fraction <= 1)
        #expect((state["total"]?.doubleValue ?? 0) > 1_000_000_000)
    }

    @Test("cpu needs two samples before it means anything")
    func cpu() async throws {
        let store = StateStore()
        let module = try CPUModule(context: ModuleContext(item: "cpu", store: store))
        #expect(await module.poll().patch?["load"]?.doubleValue == 0)
        let second = await module.poll()
        let load = second.patch?["load"]?.doubleValue ?? -1
        #expect(load >= 0 && load <= 100)
    }
}
