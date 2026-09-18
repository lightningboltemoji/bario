import QuartzCore

/// The present stage for one bar's scene (DESIGN.md §10). It holds the target scene and when
/// each transition started, never the scene on screen: asking it about a moment gives what
/// should be on screen then, so retargeting mid-transition eases from exactly what is showing
/// and progress is read off the clock rather than accumulated per tick.
public struct Animator {
    /// The scene layout produced last.
    public private(set) var target: Scene?
    /// Per item name, whatever is still easing toward the target.
    private var motions: [String: Motion] = [:]
    /// The bar's own style, which transitions like an item's.
    private var bar = StyleMotion()

    public init() {}

    struct Tween<Value> {
        var from: Value
        var start: CFTimeInterval
        var transition: Transition

        var end: CFTimeInterval { start + transition.delay + transition.duration }

        func isActive(at now: CFTimeInterval) -> Bool { now < end }

        /// Eased progress, 0 until the delay has passed and 1 from the end on.
        func progress(at now: CFTimeInterval) -> Double {
            let elapsed = now - start - transition.delay
            guard elapsed > 0 else { return 0 }
            guard transition.duration > 0, elapsed < transition.duration else { return 1 }
            return transition.easing.evaluate(elapsed / transition.duration)
        }
    }

    /// Style transitions for one item: per property, the value it started from and when.
    struct StyleMotion {
        var tweens: [StyleProperty: Tween<Style>] = [:]

        func isMoving(at now: CFTimeInterval) -> Bool {
            tweens.values.contains { $0.isActive(at: now) }
        }

        func sample(_ target: Style, at now: CFTimeInterval) -> Style {
            var style = target
            for (property, tween) in tweens {
                style.blend(property, from: tween.from, t: tween.progress(at: now))
            }
            return style
        }

        /// Start a transition for every property whose target changed and which has one.
        /// Properties still easing toward an unchanged target carry on undisturbed.
        mutating func retarget(from old: Style, to new: Style, at now: CFTimeInterval) {
            let shown = sample(old, at: now)
            for property in StyleProperty.animatable where old.differs(in: property, from: new) {
                if let transition = new.transition(for: property.rawValue),
                   transition.duration + transition.delay > 0 {
                    tweens[property] = Tween(from: shown, start: now, transition: transition)
                } else {
                    tweens[property] = nil
                }
            }
            tweens = tweens.filter { $0.value.isActive(at: now) }
        }
    }

    struct Motion {
        var style = StyleMotion()
        var frame: Tween<CGRect>?

        func isMoving(at now: CFTimeInterval) -> Bool {
            style.isMoving(at: now) || frame?.isActive(at: now) == true
        }
    }

    public func isMoving(at now: CFTimeInterval) -> Bool {
        bar.isMoving(at: now) || motions.values.contains { $0.isMoving(at: now) }
    }

    /// Point the animation at a new scene. With `animated` false, or with nothing on screen
    /// before, the scene is simply taken: a bar that is not on screen has nothing to ease from.
    public mutating func retarget(_ scene: Scene, at now: CFTimeInterval, animated: Bool = true) {
        defer { target = scene }
        guard animated, let old = target else {
            motions = [:]
            bar = StyleMotion()
            return
        }

        bar.retarget(from: old.style, to: scene.style, at: now)
        let layout = scene.style.transitions.last { $0.property == "layout" }
        let before = Dictionary(old.allItems.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var next: [String: Motion] = [:]
        for item in scene.allItems {
            // An item that was not there before is placed where it belongs rather than grown
            // out of nothing; its neighbours still slide to make room.
            guard let previous = before[item.name] else { continue }
            var motion = motions[item.name] ?? Motion()
            motion.style.retarget(from: previous.style, to: item.style, at: now)

            if previous.frame != item.frame {
                // Content arriving for the first time is the item appearing, not resizing.
                let appearing = previous.states.contains(.empty) && !item.states.contains(.empty)
                if let layout, layout.duration + layout.delay > 0, !appearing {
                    let shown = motion.frame.map { Animator.sample($0, to: previous.frame, at: now) }
                        ?? previous.frame
                    motion.frame = Tween(from: shown, start: now, transition: layout)
                } else {
                    motion.frame = nil
                }
            } else if motion.frame?.isActive(at: now) == false {
                motion.frame = nil
            }
            if motion.isMoving(at: now) { next[item.name] = motion }
        }
        motions = next
    }

    /// The scene as it should be on screen at `now`.
    public func presented(at now: CFTimeInterval) -> Scene? {
        guard var scene = target else { return nil }
        guard !motions.isEmpty || !bar.tweens.isEmpty else { return scene }
        scene.style = bar.sample(scene.style, at: now)
        scene.rows = scene.rows.map { row in
            var row = row
            row.items = row.items.map { present($0, at: now) }
            return row
        }
        return scene
    }

    private func present(_ item: SceneItem, at now: CFTimeInterval) -> SceneItem {
        var item = item
        // The items in a group follow their own rectangles, which already include the group's
        // movement, so a group never moves its children itself.
        item.children = item.children.map { present($0, at: now) }
        guard let motion = motions[item.name] else { return item }

        if motion.style.isMoving(at: now) {
            let target = item.style
            item.style = motion.style.sample(target, at: now)
            item.content = item.content.map { Animator.inherit($0, from: target, as: item.style) }
        }
        if let tween = motion.frame, tween.isActive(at: now) {
            item = Animator.move(item, to: Animator.sample(tween, to: item.frame, at: now))
        }
        return item
    }

    static func sample(_ tween: Tween<CGRect>, to target: CGRect, at now: CFTimeInterval) -> CGRect {
        let t = tween.progress(at: now)
        guard t < 1 else { return target }
        return CGRect(x: lerp(tween.from.minX, target.minX, t),
                      y: lerp(tween.from.minY, target.minY, t),
                      width: lerp(tween.from.width, target.width, t),
                      height: lerp(tween.from.height, target.height, t))
    }

    /// Content inherits from its item, so an item's colour easing has to reach the text that
    /// took its colour from the item. A node that set its own value keeps it.
    static func inherit(_ node: SceneNode, from target: Style, as shown: Style) -> SceneNode {
        var node = node
        for property in StyleProperty.animatable where property.isInherited {
            if !node.style.differs(in: property, from: target) {
                node.style.take(property, from: shown)
            }
        }
        node.children = node.children.map { inherit($0, from: target, as: shown) }
        return node
    }

    /// Put an item at an in-between frame. While a bubble resizes, its content keeps the size
    /// it was measured at and stays centred in the bubble.
    static func move(_ item: SceneItem, to frame: CGRect) -> SceneItem {
        guard frame != item.frame else { return item }
        var item = item
        let delta = CGSize(width: frame.midX - item.frame.midX, height: frame.midY - item.frame.midY)
        item.frame = frame
        item.content = item.content.map { offset($0, by: delta) }
        return item
    }

    static func offset(_ node: SceneNode, by delta: CGSize) -> SceneNode {
        var node = node
        node.frame = node.frame.offsetBy(dx: delta.width, dy: delta.height)
        node.children = node.children.map { offset($0, by: delta) }
        return node
    }
}
