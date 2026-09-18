import Foundation

/// Where `emit` and `subscribe` actually go. DESIGN.md §4 and §5 give modules and socket
/// clients the same two verbs, so they meet here: anything posted reaches the socket and every
/// module that asked for it, wherever it came from.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    /// item name → the topics that item wants to hear about.
    private var topics: [String: [SocketTopic]] = [:]
    private var handler: (@Sendable (ModuleEvent, String?) -> Void)?

    public init() {}

    /// Set by the controller: broadcast to socket subscribers and deliver to modules.
    public func onPost(_ handler: @escaping @Sendable (ModuleEvent, String?) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    public func subscribe(item: String, topic: String) {
        lock.lock(); defer { lock.unlock() }
        topics[item, default: []].append(SocketTopic(topic))
    }

    public func forget(_ item: String) {
        lock.lock(); topics.removeValue(forKey: item); lock.unlock()
    }

    /// `from` is the item that emitted it, so it is not handed its own event back.
    public func post(_ event: ModuleEvent, from item: String? = nil) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(event, item)
    }

    /// Which items asked to hear about this topic. `state:battery.pct`, `click:volume`,
    /// `event:refresh`.
    public func subscribers(of topic: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return topics.compactMap { item, patterns in
            patterns.contains { $0.matches(topic) } ? item : nil
        }.sorted()
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return topics.isEmpty
    }
}
