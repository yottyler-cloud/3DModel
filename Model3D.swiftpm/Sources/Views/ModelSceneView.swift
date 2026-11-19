import SwiftUI
import SceneKit
import UIKit

/// 3D表示(SceneKit)。指1本で回転、2本で移動、ピンチで拡大縮小
struct ModelSceneView: UIViewRepresentable {
    var mesh: TriMesh
    var meshVersion: Int
    /// 強調表示するスケッチ(選択中の特徴)
    var highlight: Sketch?
    var fitRequest: Int
    var viewRequest: ViewDirection?

    enum ViewDirection: Equatable {
        case iso, top, front, right
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
                : UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        }
        view.pointOfView = context.coordinator.cameraNode
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        context.coordinator.view = view
        context.coordinator.fit(.iso)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        if c.meshVersion != meshVersion {
            let wasEmpty = c.bounds.isEmpty
            c.meshVersion = meshVersion
            c.setMesh(mesh)
            if wasEmpty && !mesh.bounds.isEmpty { c.fit(.iso) }
        }
        if c.highlight != highlight {
            c.highlight = highlight
            c.setHighlight(highlight)
        }
        if c.fitRequest != fitRequest {
            c.fitRequest = fitRequest
            c.fit(viewRequest ?? .iso)
        }
    }

    final class Coordinator {
        let scene = SCNScene()
        /// モデル座標(Z上)を SceneKit(Y上)へ回すための親ノード
        let world = SCNNode()
        let modelNode = SCNNode()
        let highlightNode = SCNNode()
        let gridNode = SCNNode()
        let cameraNode = SCNNode()
        weak var view: SCNView?
        var meshVersion = -1
        var highlight: Sketch?
        var fitRequest = 0
        var bounds = Box3()

        init() {
            world.eulerAngles.x = -.pi / 2
            scene.rootNode.addChildNode(world)
            world.addChildNode(modelNode)
            world.addChildNode(highlightNode)
            world.addChildNode(gridNode)

            let camera = SCNCamera()
            camera.zNear = 0.5
            camera.zFar = 20000
            camera.fieldOfView = 35
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 350
            scene.rootNode.addChildNode(ambient)

            // カメラについてくる光と、上からの光
            let head = SCNNode()
            head.light = SCNLight()
            head.light?.type = .directional
            head.light?.intensity = 700
            cameraNode.addChildNode(head)

            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 350
            sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
            scene.rootNode.addChildNode(sun)

            buildGrid(size: 200, step: 10)
        }

        func setMesh(_ mesh: TriMesh) {
            modelNode.geometry = makeGeometry(mesh)
            bounds = mesh.bounds
        }

        private func makeGeometry(_ mesh: TriMesh) -> SCNGeometry? {
            guard !mesh.positions.isEmpty else { return nil }
            let vs = mesh.positions.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let ns = mesh.normals.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let indices = (0..<Int32(vs.count)).map { $0 }
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vs), SCNGeometrySource(normals: ns)],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = UIColor(red: 0.62, green: 0.70, blue: 0.80, alpha: 1)
            m.specular.contents = UIColor(white: 0.45, alpha: 1)
            m.shininess = 0.35
            geometry.materials = [m]
            return geometry
        }

        func setHighlight(_ sketch: Sketch?) {
            highlightNode.childNodes.forEach { $0.removeFromParentNode() }
            guard let sketch else { return }
            for shape in sketch.shapes where shape.isValid {
                let pts = Polygon2D.dedupe(ProfileGeometry.outline(shape)).map {
                    sketch.plane.point($0)
                }
                guard pts.count >= 2 else { continue }
                highlightNode.addChildNode(lineNode(pts, closed: true, color: .systemOrange))
            }
        }

        private func buildGrid(size: Double, step: Double) {
            var minor: [Vec3] = []
            var x = -size
            while x <= size + 1e-9 {
                minor.append(Vec3(x, -size, 0)); minor.append(Vec3(x, size, 0))
                minor.append(Vec3(-size, x, 0)); minor.append(Vec3(size, x, 0))
                x += step
            }
            gridNode.addChildNode(segmentsNode(minor, color: UIColor.gray.withAlphaComponent(0.25)))
            gridNode.addChildNode(segmentsNode([Vec3(0, 0, 0), Vec3(size * 0.35, 0, 0)], color: .systemRed))
            gridNode.addChildNode(segmentsNode([Vec3(0, 0, 0), Vec3(0, size * 0.35, 0)], color: .systemGreen))
            gridNode.addChildNode(segmentsNode([Vec3(0, 0, 0), Vec3(0, 0, size * 0.35)], color: .systemBlue))
        }

        private func lineNode(_ pts: [Vec3], closed: Bool, color: UIColor) -> SCNNode {
            var segs: [Vec3] = []
            for i in 0..<(closed ? pts.count : pts.count - 1) {
                segs.append(pts[i])
                segs.append(pts[(i + 1) % pts.count])
            }
            return segmentsNode(segs, color: color)
        }

        private func segmentsNode(_ segs: [Vec3], color: UIColor) -> SCNNode {
            let vs = segs.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            let indices = (0..<Int32(vs.count)).map { $0 }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vs)],
                                elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.readsFromDepthBuffer = true
            g.materials = [m]
            let node = SCNNode(geometry: g)
            node.renderingOrder = 10
            return node
        }

        /// モデル全体が見えるようにカメラを置く
        func fit(_ dir: ViewDirection) {
            let b = bounds.isEmpty ? Box3(min: Vec3(-50, -50, 0), max: Vec3(50, 50, 20)) : bounds
            // モデル座標(Z上) → SceneKit座標(Y上): (x, y, z) → (x, z, -y)
            func toScene(_ v: Vec3) -> SCNVector3 { SCNVector3(Float(v.x), Float(v.z), Float(-v.y)) }
            let center = toScene(b.center)
            let radius = max(b.size.length * 0.5, 10)
            let dist = Float(radius / sin(35.0 / 2 * Double.pi / 180) * 1.1)
            let dirVec: SCNVector3
            switch dir {
            case .iso: dirVec = toScene(Vec3(1, -1.2, 0.9).normalized)
            case .top: dirVec = toScene(Vec3(0, 0, 1))
            case .front: dirVec = toScene(Vec3(0, -1, 0))
            case .right: dirVec = toScene(Vec3(1, 0, 0))
            }
            cameraNode.position = SCNVector3(center.x + dirVec.x * dist,
                                             center.y + dirVec.y * dist,
                                             center.z + dirVec.z * dist)
            let up = dir == .top ? SCNVector3(0, 0, -1) : SCNVector3(0, 1, 0)
            cameraNode.look(at: center, up: up, localFront: SCNVector3(0, 0, -1))
            if let view {
                view.pointOfView = cameraNode
                view.defaultCameraController.target = center
            }
        }
    }
}
