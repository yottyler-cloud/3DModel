import SwiftUI
import UIKit

/// スケッチ画面の入力面。指1本(またはApple Pencil)は作図、
/// 指2本のドラッグで移動、ピンチで拡大縮小。
struct TouchSurface: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onMoved: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void
    var onPan: (CGSize) -> Void
    var onPinch: (CGFloat, CGPoint) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(target: v, action: #selector(TouchView.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = v
        let pinch = UIPinchGestureRecognizer(target: v, action: #selector(TouchView.handlePinch(_:)))
        pinch.delegate = v
        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(pinch)
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) {
        v.handlers = self
    }

    final class TouchView: UIView, UIGestureRecognizerDelegate {
        var handlers: TouchSurface?
        private var activeTouch: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if activeTouch == nil, event?.allTouches?.count ?? 1 == 1, let t = touches.first {
                activeTouch = t
                handlers?.onBegan(t.location(in: self))
            } else if activeTouch != nil {
                // 2本目の指が来たら作図をやめる
                activeTouch = nil
                handlers?.onCancelled()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = activeTouch, touches.contains(t) else { return }
            handlers?.onMoved(t.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = activeTouch, touches.contains(t) else { return }
            activeTouch = nil
            handlers?.onEnded(t.location(in: self))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = activeTouch, touches.contains(t) else { return }
            activeTouch = nil
            handlers?.onCancelled()
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let tr = g.translation(in: self)
            handlers?.onPan(CGSize(width: tr.x, height: tr.y))
            g.setTranslation(.zero, in: self)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            handlers?.onPinch(g.scale, g.location(in: self))
            g.scale = 1
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
