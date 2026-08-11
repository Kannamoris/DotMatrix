import UIKit
import SwiftUI

/// On-screen controls.
///
/// Written in UIKit because this needs genuine multitouch: holding a direction
/// while tapping B, and rolling a thumb across the D-pad into a diagonal, both
/// require tracking several touches independently and hit-testing each on every
/// move. SwiftUI's gesture system collapses that into a single sequence.
final class GamepadView: UIView {
    var onButtonsChanged: ((GBAButtons) -> Void)?
    /// Fires on any newly pressed button, for haptics.
    var onPress: (() -> Void)?

    private var pressed: GBAButtons = [] {
        didSet {
            guard pressed != oldValue else { return }
            setNeedsDisplay()
            onButtonsChanged?(pressed)
            if !pressed.subtracting(oldValue).isEmpty {
                onPress?()
            }
        }
    }

    /// Which button each active touch is currently over.
    private var touchAssignments: [ObjectIdentifier: GBAButtons] = [:]

    // Layout, recomputed in `layoutSubviews`.
    private var dpadCenter: CGPoint = .zero
    private var dpadRadius: CGFloat = 0
    private var aCenter: CGPoint = .zero
    private var bCenter: CGPoint = .zero
    private var faceRadius: CGFloat = 0
    private var startRect: CGRect = .zero
    private var selectRect: CGRect = .zero
    private var shoulderLeftRect: CGRect = .zero
    private var shoulderRightRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let inset = safeAreaInsets
        let usable = bounds.inset(by: UIEdgeInsets(
            top: inset.top, left: max(inset.left, 16),
            bottom: max(inset.bottom, 16), right: max(inset.right, 16)
        ))

        // Scale with the shorter edge so the controls stay thumb-sized on both
        // a small phone and an iPad.
        let unit = min(usable.width, usable.height * 1.6)

        dpadRadius = min(unit * 0.20, 92)
        faceRadius = min(unit * 0.085, 38)

        let clusterY = usable.maxY - dpadRadius - 24

        dpadCenter = CGPoint(x: usable.minX + dpadRadius + 8, y: clusterY)

        // A sits lower-right of B, matching the hardware's diagonal.
        let faceOrigin = CGPoint(x: usable.maxX - faceRadius - 12, y: clusterY)
        aCenter = CGPoint(x: faceOrigin.x, y: faceOrigin.y - faceRadius * 0.55)
        bCenter = CGPoint(x: faceOrigin.x - faceRadius * 2.35, y: faceOrigin.y + faceRadius * 0.75)

        let pillWidth = min(usable.width * 0.17, 92.0)
        let pillHeight: CGFloat = 30
        let pillY = usable.maxY - pillHeight - 4
        let gap: CGFloat = 16
        let pairWidth = pillWidth * 2 + gap
        let pairX = usable.midX - pairWidth / 2

        selectRect = CGRect(x: pairX, y: pillY, width: pillWidth, height: pillHeight)
        startRect = CGRect(x: pairX + pillWidth + gap, y: pillY, width: pillWidth, height: pillHeight)

        // Shoulders sit at the upper corners, where the index fingers rest when
        // the phone is held like a handheld.
        let shoulderWidth = min(usable.width * 0.22, 110.0)
        let shoulderHeight: CGFloat = 34
        let shoulderY = usable.minY + 4
        shoulderLeftRect = CGRect(x: usable.minX, y: shoulderY,
                                  width: shoulderWidth, height: shoulderHeight)
        shoulderRightRect = CGRect(x: usable.maxX - shoulderWidth, y: shoulderY,
                                   width: shoulderWidth, height: shoulderHeight)

        setNeedsDisplay()
    }

    // MARK: Hit testing

    /// Which buttons a point activates. The D-pad returns up to two so that
    /// corners register as diagonals.
    private func buttons(at point: CGPoint) -> GBAButtons {
        // Face buttons get a generous radius — larger than they are drawn —
        // because thumbs land imprecisely and a missed A press is worse than
        // an occasional overlap.
        let touchRadius = faceRadius * 1.45
        if hypot(point.x - aCenter.x, point.y - aCenter.y) <= touchRadius { return .a }
        if hypot(point.x - bCenter.x, point.y - bCenter.y) <= touchRadius { return .b }

        if startRect.insetBy(dx: -12, dy: -14).contains(point) { return .start }
        if selectRect.insetBy(dx: -12, dy: -14).contains(point) { return .select }

        if shoulderLeftRect.insetBy(dx: -8, dy: -12).contains(point) { return .l }
        if shoulderRightRect.insetBy(dx: -8, dy: -12).contains(point) { return .r }

        let dx = point.x - dpadCenter.x
        let dy = point.y - dpadCenter.y
        // A square region rather than a circle, so the corners are reachable.
        guard abs(dx) <= dpadRadius * 1.15 && abs(dy) <= dpadRadius * 1.15 else { return [] }

        // Inside a small centre deadzone, register nothing — this stops a thumb
        // resting in the middle from firing spurious directions.
        let deadzone = dpadRadius * 0.22
        if abs(dx) < deadzone && abs(dy) < deadzone { return [] }

        var result: GBAButtons = []
        // A direction engages once the axis is past a third of the other, which
        // yields comfortable 45-degree diagonal wedges.
        if abs(dx) > deadzone && abs(dx) > abs(dy) * 0.4 {
            result.insert(dx > 0 ? .right : .left)
        }
        if abs(dy) > deadzone && abs(dy) > abs(dx) * 0.4 {
            result.insert(dy > 0 ? .down : .up)
        }
        return result
    }

    private func recomputePressed() {
        var combined: GBAButtons = []
        for assignment in touchAssignments.values {
            combined.formUnion(assignment)
        }
        pressed = combined
    }

    // MARK: Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchAssignments[ObjectIdentifier(touch)] = buttons(at: touch.location(in: self))
        }
        recomputePressed()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            // Re-hit-test on every move so a thumb can slide between directions
            // without lifting.
            touchAssignments[ObjectIdentifier(touch)] = buttons(at: touch.location(in: self))
        }
        recomputePressed()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchAssignments.removeValue(forKey: ObjectIdentifier(touch))
        }
        recomputePressed()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let idle = UIColor.label.withAlphaComponent(0.16)
        let active = UIColor.label.withAlphaComponent(0.42)
        let stroke = UIColor.label.withAlphaComponent(0.28)

        // D-pad, drawn as a plus made of two rounded rectangles.
        let armThickness = dpadRadius * 0.66
        let vertical = CGRect(
            x: dpadCenter.x - armThickness / 2, y: dpadCenter.y - dpadRadius,
            width: armThickness, height: dpadRadius * 2)
        let horizontal = CGRect(
            x: dpadCenter.x - dpadRadius, y: dpadCenter.y - armThickness / 2,
            width: dpadRadius * 2, height: armThickness)

        let dpadPath = UIBezierPath(roundedRect: vertical, cornerRadius: 10)
        dpadPath.append(UIBezierPath(roundedRect: horizontal, cornerRadius: 10))
        idle.setFill()
        dpadPath.fill()

        // Highlight the engaged arms.
        context.saveGState()
        active.setFill()
        let half = armThickness / 2
        if pressed.contains(.up) {
            UIBezierPath(roundedRect: CGRect(x: dpadCenter.x - half, y: dpadCenter.y - dpadRadius,
                                             width: armThickness, height: dpadRadius - half),
                         cornerRadius: 8).fill()
        }
        if pressed.contains(.down) {
            UIBezierPath(roundedRect: CGRect(x: dpadCenter.x - half, y: dpadCenter.y + half,
                                             width: armThickness, height: dpadRadius - half),
                         cornerRadius: 8).fill()
        }
        if pressed.contains(.left) {
            UIBezierPath(roundedRect: CGRect(x: dpadCenter.x - dpadRadius, y: dpadCenter.y - half,
                                             width: dpadRadius - half, height: armThickness),
                         cornerRadius: 8).fill()
        }
        if pressed.contains(.right) {
            UIBezierPath(roundedRect: CGRect(x: dpadCenter.x + half, y: dpadCenter.y - half,
                                             width: dpadRadius - half, height: armThickness),
                         cornerRadius: 8).fill()
        }
        context.restoreGState()

        stroke.setStroke()
        dpadPath.lineWidth = 1
        dpadPath.stroke()

        drawFaceButton(at: bCenter, label: "B", isPressed: pressed.contains(.b),
                       idle: idle, active: active, stroke: stroke)
        drawFaceButton(at: aCenter, label: "A", isPressed: pressed.contains(.a),
                       idle: idle, active: active, stroke: stroke)

        drawPill(selectRect, label: "SELECT", isPressed: pressed.contains(.select),
                 idle: idle, active: active, stroke: stroke)
        drawPill(startRect, label: "START", isPressed: pressed.contains(.start),
                 idle: idle, active: active, stroke: stroke)

        drawPill(shoulderLeftRect, label: "L", isPressed: pressed.contains(.l),
                 idle: idle, active: active, stroke: stroke)
        drawPill(shoulderRightRect, label: "R", isPressed: pressed.contains(.r),
                 idle: idle, active: active, stroke: stroke)
    }

    private func drawFaceButton(at center: CGPoint, label: String, isPressed: Bool,
                                idle: UIColor, active: UIColor, stroke: UIColor) {
        let rect = CGRect(x: center.x - faceRadius, y: center.y - faceRadius,
                          width: faceRadius * 2, height: faceRadius * 2)
        let path = UIBezierPath(ovalIn: rect)
        (isPressed ? active : idle).setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: faceRadius * 0.8, weight: .semibold),
            .foregroundColor: UIColor.label.withAlphaComponent(0.55),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                   withAttributes: attributes)
    }

    private func drawPill(_ rect: CGRect, label: String, isPressed: Bool,
                          idle: UIColor, active: UIColor, stroke: UIColor) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        (isPressed ? active : idle).setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.label.withAlphaComponent(0.55),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                   withAttributes: attributes)
    }
}

/// SwiftUI wrapper for `GamepadView`.
struct Gamepad: UIViewRepresentable {
    let onButtonsChanged: (GBAButtons) -> Void
    var hapticsEnabled: Bool

    func makeUIView(context: Context) -> GamepadView {
        let view = GamepadView()
        view.onButtonsChanged = onButtonsChanged
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        view.onPress = { [weak generator] in
            guard context.coordinator.hapticsEnabled else { return }
            generator?.impactOccurred(intensity: 0.5)
        }
        return view
    }

    func updateUIView(_ uiView: GamepadView, context: Context) {
        uiView.onButtonsChanged = onButtonsChanged
        context.coordinator.hapticsEnabled = hapticsEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hapticsEnabled: hapticsEnabled)
    }

    final class Coordinator {
        var hapticsEnabled: Bool
        init(hapticsEnabled: Bool) {
            self.hapticsEnabled = hapticsEnabled
        }
    }
}
