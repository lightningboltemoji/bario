import QuartzCore

/// `transform` and `animation` as layer properties (DESIGN.md §9, PLAN.md step 3b). A transform
/// turns and scales about the centre of the layer's box, which is where every compositor layer
/// has its anchor. An animation is Core Animation's to run: bario adds it once and sleeps while
/// it plays.
@MainActor
final class Motion {
    struct Added {
        var animation: Animation
        /// When it stops having any effect, in the layer's time; infinity for `infinite`.
        var ends: CFTimeInterval
    }

    /// By key, the animations this layer was given and what each was made from.
    private(set) var added: [String: Added] = [:]

    func apply(_ style: Style, to layer: CALayer, animationTime: CFTimeInterval?) {
        let matrix = style.transform.matrix
        if !CATransform3DEqualToTransform(layer.transform, matrix) { layer.transform = matrix }
        // Siblings share a 3D space, so a box tipped out of the bar's plane is cut where it
        // passes behind the backdrop. Lifted far in front, it is ordered over its neighbours
        // instead; a lift changes no projection.
        let lift: CGFloat = style.turnsInDepth ? Motion.lift : 0
        if layer.zPosition != lift { layer.zPosition = lift }

        guard !style.animations.isEmpty || !added.isEmpty else { return }
        let now = animationTime ?? layer.convertTime(CACurrentMediaTime(), from: nil)
        var wanted: Set<String> = []
        for animation in style.animations where animation.iterations > 0 {
            for track in animation.tracks(from: style) {
                let key = "bario.\(animation.name).\(track.keyPath)"
                wanted.insert(key)
                // Added once, and replaced only when its definition changes, so no commit
                // restarts a spinner (PLAN.md D12). One that went missing while it should still
                // be running, with its layer moved to another parent, is added again.
                if let previous = added[key], previous.animation == animation,
                   layer.animation(forKey: key) != nil || previous.ends <= now {
                    continue
                }
                let begin = now + animation.delay
                layer.add(track.animation(for: animation, beginTime: begin), forKey: key)
                added[key] = Added(animation: animation,
                                   ends: begin + animation.duration * animation.iterations)
            }
        }
        for key in added.keys where !wanted.contains(key) {
            layer.removeAnimation(forKey: key)
            added[key] = nil
        }
    }
}

extension Motion {
    static let lift: CGFloat = 10_000
}

extension Style {
    /// Whether this box turns out of the bar's plane, now or in an animation.
    var turnsInDepth: Bool {
        transform.turnsInDepth || animations.contains { $0.keyframes.contains { $0.transform?.turnsInDepth == true } }
    }
}

extension Transform {
    var turnsInDepth: Bool { rotateX != 0 || rotateY != 0 }

    /// Scale, then rotateY, rotateX and rotate, then perspective, then translate, with y up and
    /// every angle turning the way it does in CSS.
    var matrix: CATransform3D {
        var matrix = CATransform3DMakeTranslation(translateX, -translateY, 0)
        if perspective > 0 {
            var eye = CATransform3DIdentity
            eye.m34 = -1 / perspective
            matrix = CATransform3DConcat(eye, matrix)
        }
        matrix = CATransform3DRotate(matrix, -rotate * .pi / 180, 0, 0, 1)
        if rotateX != 0 { matrix = CATransform3DRotate(matrix, -rotateX * .pi / 180, 1, 0, 0) }
        if rotateY != 0 { matrix = CATransform3DRotate(matrix, rotateY * .pi / 180, 0, 1, 0) }
        return CATransform3DScale(matrix, scaleX, scaleY, 1)
    }
}

extension Animation {
    /// One property an animation moves, as a Core Animation key path and a value per keyframe.
    struct Track {
        var keyPath: String
        var keyTimes: [Double]
        var values: [Double]

        func animation(for animation: Animation, beginTime: CFTimeInterval) -> CAKeyframeAnimation {
            let result = CAKeyframeAnimation(keyPath: keyPath)
            result.values = values.map { NSNumber(value: $0) }
            result.keyTimes = keyTimes.map { NSNumber(value: $0) }
            result.calculationMode = .linear
            // CSS eases each interval between keyframes, not the whole run.
            result.timingFunctions = Array(repeating: animation.easing.timingFunction,
                                           count: max(1, values.count - 1))
            result.duration = animation.duration
            result.beginTime = beginTime
            // An alternate iteration is one way; a Core Animation repeat that autoreverses is
            // there and back.
            result.autoreverses = animation.alternate
            result.repeatCount = Float(animation.alternate ? animation.iterations / 2 : animation.iterations)
            result.isRemovedOnCompletion = false
            return result
        }
    }

    /// A track per component that moves: a matrix eased from 0° to 360° is no turn at all, so
    /// rotation, scale and translation each run on their own key path. A keyframe that does not
    /// mention a property leaves it out of that property's track, and a track that does not
    /// start at 0 or end at 1 starts or ends at the style's own value, as in CSS.
    func tracks(from style: Style) -> [Track] {
        let components: [(String, (Transform) -> Double)] = [
            ("transform.translation.x", { $0.translateX }),
            ("transform.translation.y", { -$0.translateY }),
            ("transform.rotation.z", { -$0.rotate * .pi / 180 }),
            ("transform.rotation.x", { -$0.rotateX * .pi / 180 }),
            ("transform.rotation.y", { $0.rotateY * .pi / 180 }),
            ("transform.scale.x", { $0.scaleX }),
            ("transform.scale.y", { $0.scaleY }),
        ]
        var tracks: [Track] = []
        for (keyPath, value) in components {
            let points = keyframes.compactMap { frame in frame.transform.map { (frame.offset, value($0)) } }
            if let track = Animation.track(keyPath, points, base: value(style.transform)) {
                tracks.append(track)
            }
        }
        let opacity = keyframes.compactMap { frame in frame.opacity.map { (frame.offset, $0) } }
        if let track = Animation.track("opacity", opacity, base: style.opacity) {
            tracks.append(track)
        }
        return tracks
    }

    private static func track(_ keyPath: String, _ points: [(Double, Double)], base: Double) -> Track? {
        guard !points.isEmpty, points.contains(where: { $0.1 != base }) else { return nil }
        var points = points
        if points[0].0 > 0 { points.insert((0, base), at: 0) }
        if points[points.count - 1].0 < 1 { points.append((1, base)) }
        return Track(keyPath: keyPath, keyTimes: points.map(\.0), values: points.map(\.1))
    }
}

extension Easing {
    var timingFunction: CAMediaTimingFunction {
        switch self {
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        }
    }
}
