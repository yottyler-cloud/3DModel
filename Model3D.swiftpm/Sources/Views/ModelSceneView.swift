import SwiftUI
import SceneKit
import UIKit

/// グラフィックス領域に重ねて描くもの
struct SceneOverlays: Equatable {
    struct SketchLines: Equatable {
        var plane: SketchPlane
        var shapes: [SketchShape]
        var emphasized: Bool
    }
    var sketches: [SketchLines] = []
    var faceTriangles: [Int] = []
    var plane: SketchPlane?
    var selectedEdges: [EdgeCandidate] = []
}

/// スケッチ中のカメラ(平面に垂直・平行投影で、2Dのスケッチ画面と同じ範囲を映す)
struct SketchCamera: Equatable {
    var plane: SketchPlane
    var center: Vec2
    var halfHeight: Double
}

/// 3D表示(SceneKit)。指1本で回転、2本で移動、ピンチで拡大縮小、タップで選択
struct ModelSceneView: UIViewRepresentable {
    var mesh: TriMesh
    var meshVersion: Int
    var showEdges: Bool
    var overlays: SceneOverlays
    var viewCommand: ViewCommand
    var sketchCamera: SketchCamera?
    var edgeCandidates: [EdgeCandidate]
    var onTap: (SceneHit?, EdgeRef?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let c = context.coordinator
        view.scene = c.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .white
        view.pointOfView = c.cameraNode
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        c.view = view
        c.fit(.iso)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.candidates = edgeCandidates
        c.meshForPick = mesh
        if c.meshVersion != meshVersion {
            let wasEmpty = c.bounds.isEmpty
            c.meshVersion = meshVersion
            c.setMesh(mesh)
            if wasEmpty && !mesh.bounds.isEmpty && sketchCamera == nil { c.fit(.iso) }
        }
        c.edgesNode.isHidden = !showEdges
        if c.overlays != overlays {
            c.overlays = overlays
            c.setOverlays(overlays, mesh: mesh)
        }
        if let sc = sketchCamera {
            c.applySketchCamera(sc)
        } else if c.inSketch {
            c.leaveSketchCamera()
        }
        if c.viewSerial != viewCommand.serial {
            c.viewSerial = viewCommand.serial
            if sketchCamera == nil { c.fit(viewCommand.kind) }
        }
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let modelNode = SCNNode()
        let edgesNode = SCNNode()
        let overlayNode = SCNNode()
        let originNode = SCNNode()
        let cameraNode = SCNNode()
        weak var view: SCNView?
        var meshVersion = -1
        var viewSerial = 0
        var overlays = SceneOverlays()
        var bounds = Box3()
        var inSketch = false
        var candidates: [EdgeCandidate] = []
        var meshForPick = TriMesh()
        var onTap: ((SceneHit?, EdgeRef?) -> Void)?

        override init() {
            super.init()
            scene.background.contents = Coordinator.backgroundImage()
            scene.rootNode.addChildNode(modelNode)
            scene.rootNode.addChildNode(edgesNode)
            scene.rootNode.addChildNode(overlayNode)
            scene.rootNode.addChildNode(originNode)

            let camera = SCNCamera()
            camera.zNear = 0.5
            camera.zFar = 100_000
            camera.fieldOfView = 30
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 380
            scene.rootNode.addChildNode(ambient)

            let head = SCNNode()
            head.light = SCNLight()
            head.light?.type = .directional
            head.light?.intensity = 650
            cameraNode.addChildNode(head)

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 300
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)

            // 原点の3軸
            let l = 12.0
            originNode.addChildNode(Coordinator.segments([.zero, Vec3(l, 0, 0)], color: .systemRed))
            originNode.addChildNode(Coordinator.segments([.zero, Vec3(0, l, 0)], color: .systemGreen))
            originNode.addChildNode(Coordinator.segments([.zero, Vec3(0, 0, l)], color: .systemBlue))
        }

        static func backgroundImage() -> UIImage {
            let size = CGSize(width: 8, height: 256)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let colors = [UIColor(red: 0.80, green: 0.86, blue: 0.94, alpha: 1).cgColor,
                              UIColor(red: 0.98, green: 0.98, blue: 1.0, alpha: 1).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
            }
        }

        // MARK: 形

        func setMesh(_ mesh: TriMesh) {
            bounds = mesh.bounds
            modelNode.geometry = Coordinator.geometry(mesh)
            edgesNode.childNodes.forEach { $0.removeFromParentNode() }
            if !mesh.edges.isEmpty {
                edgesNode.addChildNode(Coordinator.segments(mesh.edges, color: UIColor(white: 0.1, alpha: 1)))
            }
            // 面の選択表示は三角形の番号を使うので、形が変わったら作り直す
            setOverlays(overlays, mesh: mesh)
        }

        static func geometry(_ mesh: TriMesh) -> SCNGeometry? {
            guard !mesh.positions.isEmpty else { return nil }
            let vs = mesh.positions.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let ns = mesh.normals.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let indices = (0..<Int32(vs.count)).map { $0 }
            let g = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vs), SCNGeometrySource(normals: ns)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = UIColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1)
            m.specular.contents = UIColor(white: 0.5, alpha: 1)
            m.shininess = 0.4
            g.materials = [m]
            return g
        }

        static func segments(_ segs: [Vec3], color: UIColor, onTop: Bool = false) -> SCNNode {
            let vs = segs.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let indices = (0..<Int32(vs.count)).map { $0 }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vs)],
                                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.readsFromDepthBuffer = !onTop
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.renderingOrder = onTop ? 100 : 10
            return node
        }

        static func loopSegments(_ pts: [Vec3], closed: Bool) -> [Vec3] {
            var segs: [Vec3] = []
            guard pts.count >= 2 else { return segs }
            for i in 0..<(closed ? pts.count : pts.count - 1) {
                segs.append(pts[i])
                segs.append(pts[(i + 1) % pts.count])
            }
            return segs
        }

        /// 太い線(細い円柱をつなぐ)
        static func tube(_ pts: [Vec3], closed: Bool, radius: Double, color: UIColor) -> SCNNode {
            let node = SCNNode()
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.readsFromDepthBuffer = false
            let segs = loopSegments(pts, closed: closed)
            var i = 0
            while i + 1 < segs.count {
                let a = segs[i], b = segs[i + 1]
                i += 2
                let len = (b - a).length
                if len < 1e-6 { continue }
                let cyl = SCNCylinder(radius: CGFloat(radius), height: CGFloat(len))
                cyl.radialSegmentCount = 6
                cyl.materials = [m]
                let n = SCNNode(geometry: cyl)
                let mid = (a + b) * 0.5
                n.position = SCNVector3(Float(mid.x), Float(mid.y), Float(mid.z))
                // 円柱の軸(Y)を a→b に向ける
                let d = (b - a).normalized
                let up = Vec3(0, 1, 0)
                let axis = up.cross(d)
                let angle = acos(max(-1, min(1, up.dot(d))))
                if axis.length > 1e-9 {
                    let an = axis.normalized
                    n.rotation = SCNVector4(Float(an.x), Float(an.y), Float(an.z), Float(angle))
                } else if d.y < 0 {
                    n.rotation = SCNVector4(1, 0, 0, Float.pi)
                }
                n.renderingOrder = 120
                node.addChildNode(n)
            }
            return node
        }

        // MARK: 重ねて描くもの

        func setOverlays(_ o: SceneOverlays, mesh: TriMesh) {
            overlayNode.childNodes.forEach { $0.removeFromParentNode() }
            let size = max(bounds.isEmpty ? 100 : bounds.size.length, 20)

            for s in o.sketches {
                var segs: [Vec3] = []
                for shape in s.shapes where shape.isValid {
                    let pts = Polygon2D.dedupe(ProfileGeometry.outline(shape)).map { s.plane.point($0) }
                    segs += Coordinator.loopSegments(pts, closed: true)
                }
                if !segs.isEmpty {
                    let color: UIColor = s.emphasized ? .systemOrange : .systemBlue
                    overlayNode.addChildNode(Coordinator.segments(segs, color: color, onTop: true))
                }
            }

            if !o.faceTriangles.isEmpty, !mesh.positions.isEmpty {
                var vs: [SCNVector3] = []
                for t in o.faceTriangles where t * 3 + 2 < mesh.positions.count {
                    let n = mesh.faceNormals[t] * (size * 0.0005)
                    for k in 0..<3 {
                        let p = mesh.positions[t * 3 + k] + n
                        vs.append(SCNVector3(Float(p.x), Float(p.y), Float(p.z)))
                    }
                }
                let indices = (0..<Int32(vs.count)).map { $0 }
                let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vs)],
                                    elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.45)
                m.isDoubleSided = true
                m.writesToDepthBuffer = false
                g.materials = [m]
                let node = SCNNode(geometry: g)
                node.renderingOrder = 50
                overlayNode.addChildNode(node)
            }

            if let p = o.plane {
                // 基準平面: 形の大きさに合わせた四角
                let half = size * 0.6
                let c = bounds.isEmpty ? Vec3.zero : bounds.center
                let c2 = p.project(c)
                let corners = [Vec2(-half, -half), Vec2(half, -half), Vec2(half, half), Vec2(-half, half)]
                    .map { p.point(c2 + $0) }
                let vs = corners.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
                let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vs)],
                                    elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3],
                                                                  primitiveType: .triangles)])
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
                m.isDoubleSided = true
                m.writesToDepthBuffer = false
                g.materials = [m]
                let node = SCNNode(geometry: g)
                node.renderingOrder = 60
                overlayNode.addChildNode(node)
                overlayNode.addChildNode(Coordinator.segments(Coordinator.loopSegments(corners, closed: true),
                                                              color: .systemTeal, onTop: true))
            }

            for e in o.selectedEdges {
                overlayNode.addChildNode(Coordinator.tube(e.points, closed: e.closed,
                                                          radius: size * 0.003, color: .systemOrange))
            }
        }

        // MARK: タップ

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view, !inSketch else { return }
            let p = g.location(in: view)
            let hits = view.hitTest(p, options: [
                SCNHitTestOption.rootNode: modelNode,
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            ])
            var face: SceneHit?
            if let h = hits.first {
                let w = h.worldCoordinates
                face = SceneHit(point: Vec3(Double(w.x), Double(w.y), Double(w.z)), triangle: h.faceIndex)
            }
            onTap?(face, pickEdge(at: p, hit: face))
        }

        /// 画面上でタップに近いエッジ(手前に見えているもの)
        private func pickEdge(at p: CGPoint, hit: SceneHit?) -> EdgeRef? {
            guard let view, !candidates.isEmpty else { return nil }
            let size = max(bounds.size.length, 10)
            var found: [(EdgeRef, CGFloat, Vec3, Bool)] = []
            for c in candidates {
                let pts = c.points
                let n = c.closed ? pts.count : pts.count - 1
                var best: (CGFloat, Vec3)?
                for i in 0..<max(n, 0) {
                    let a = pts[i], b = pts[(i + 1) % pts.count]
                    let sa = view.projectPoint(SCNVector3(Float(a.x), Float(a.y), Float(a.z)))
                    let sb = view.projectPoint(SCNVector3(Float(b.x), Float(b.y), Float(b.z)))
                    let pa = CGPoint(x: CGFloat(sa.x), y: CGFloat(sa.y))
                    let pb = CGPoint(x: CGFloat(sb.x), y: CGFloat(sb.y))
                    let (d, t) = Coordinator.distanceToSegment(p, pa, pb)
                    if d < (best?.0 ?? .infinity) { best = (d, a.lerp(b, Double(t))) }
                }
                guard let b = best, b.0 < 22 else { continue }
                var score = b.0
                if c.isCornerEdge, let first = pts.first, let last = pts.last {
                    // 角の縦のエッジは、端(上下の面の角)の近くでは選ばれにくくする。
                    // 角には上下のふちも通っているので、角をタップしたらふちを選ぶ
                    let ends = [first, last].map { v -> CGPoint in
                        let s = view.projectPoint(SCNVector3(Float(v.x), Float(v.y), Float(v.z)))
                        return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
                    }
                    let nearEnd = ends.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity
                    if nearEnd < 34 { score += 30 }
                }
                found.append((c.ref, score, b.1, c.alwaysVisible))
            }
            found.sort { $0.1 < $1.1 }
            for f in found {
                // 手前の面に隠れていないか(タップした面の点がエッジの近くにあるか)
                if !f.3, let h = hit, (h.point - f.2).length > size * 0.04 {
                    // 面の点のほうがカメラに近ければ隠れている
                    let cam = cameraNode.worldPosition
                    let camV = Vec3(Double(cam.x), Double(cam.y), Double(cam.z))
                    if (h.point - camV).length < (f.2 - camV).length { continue }
                }
                return f.0
            }
            return nil
        }

        static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            var t: CGFloat = 0
            if l2 > 1e-9 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) }
            let x = a.x + dx * t, y = a.y + dy * t
            return (hypot(p.x - x, p.y - y), t)
        }

        // MARK: カメラ

        func applySketchCamera(_ sc: SketchCamera) {
            guard let view, let cam = cameraNode.camera else { return }
            if !inSketch {
                inSketch = true
                view.allowsCameraControl = false
                view.pointOfView = cameraNode
            }
            cam.usesOrthographicProjection = true
            cam.orthographicScale = sc.halfHeight
            let c = sc.plane.point(sc.center)
            let eye = c + sc.plane.normal * 5000
            cameraNode.position = SCNVector3(Float(eye.x), Float(eye.y), Float(eye.z))
            let v = sc.plane.v
            cameraNode.look(at: SCNVector3(Float(c.x), Float(c.y), Float(c.z)),
                            up: SCNVector3(Float(v.x), Float(v.y), Float(v.z)),
                            localFront: SCNVector3(0, 0, -1))
        }

        func leaveSketchCamera() {
            inSketch = false
            cameraNode.camera?.usesOrthographicProjection = false
            view?.allowsCameraControl = true
            fit(.iso)
        }

        /// 向きを決めて全体が見えるようにカメラを置く
        func fit(_ kind: ViewKind) {
            let b = bounds.isEmpty ? Box3(min: Vec3(-50, 0, -50), max: Vec3(50, 30, 50)) : bounds
            let center = b.center
            let radius = max(b.size.length * 0.5, 10)
            let dist = radius / sin(30.0 / 2 * Double.pi / 180) * 1.05
            var dir: Vec3
            var up = Vec3(0, 1, 0)
            switch kind {
            case .iso: dir = Vec3(1, 1, 1)
            case .front: dir = Vec3(0, 0, 1)
            case .back: dir = Vec3(0, 0, -1)
            case .right: dir = Vec3(1, 0, 0)
            case .left: dir = Vec3(-1, 0, 0)
            case .top: dir = Vec3(0, 1, 0); up = Vec3(0, 0, -1)
            case .bottom: dir = Vec3(0, -1, 0); up = Vec3(0, 0, 1)
            case .normal(let p): dir = p.normal; up = p.v
            case .fit:
                let pos = cameraNode.worldPosition
                let target = view?.defaultCameraController.target ?? SCNVector3(Float(center.x), Float(center.y), Float(center.z))
                dir = Vec3(Double(pos.x - target.x), Double(pos.y - target.y), Double(pos.z - target.z))
                let wu = cameraNode.worldUp
                up = Vec3(Double(wu.x), Double(wu.y), Double(wu.z))
                if dir.length < 1e-6 { dir = Vec3(1, 1, 1) }
            }
            dir = dir.normalized
            let eye = center + dir * dist
            SCNTransaction.begin()
            SCNTransaction.animationDuration = inSketch ? 0 : 0.35
            cameraNode.position = SCNVector3(Float(eye.x), Float(eye.y), Float(eye.z))
            cameraNode.look(at: SCNVector3(Float(center.x), Float(center.y), Float(center.z)),
                            up: SCNVector3(Float(up.x), Float(up.y), Float(up.z)),
                            localFront: SCNVector3(0, 0, -1))
            SCNTransaction.commit()
            if let view {
                view.pointOfView = cameraNode
                view.defaultCameraController.target = SCNVector3(Float(center.x), Float(center.y), Float(center.z))
            }
        }
    }
}
