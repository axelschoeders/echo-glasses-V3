import SwiftUI
import SceneKit

// MARK: data the AI returns (a model built from simple shapes)

struct Part3D: Decodable {
    let shape: String
    let size: [Double]?
    let position: [Double]?
    let rotation: [Double]?   // degrees
    let color: String?        // "#RRGGBB"
}

struct Model3D: Decodable {
    let name: String?
    let parts: [Part3D]
}

enum Model3DError: LocalizedError {
    case invalid
    var errorDescription: String? { "Ik kon het 3D-model niet lezen. Probeer het nog eens, of omschrijf het anders." }
}

struct Generated3D: Identifiable {
    let id = UUID()
    let model: Model3D
    let scene: SCNScene
    let camera: SCNNode
    var name: String { model.name ?? "3D-object" }
}

enum Model3DPrompt {
    static let system = """
    You design simple 3D models out of primitive shapes. Reply with ONLY one JSON object: no markdown, no explanation.
    Schema: {"name": "short Dutch name", "parts": [ {"shape": "box|sphere|cylinder|cone|capsule|torus|pyramid", "size": [..], "position": [x,y,z], "rotation": [x,y,z], "color": "#RRGGBB"} ]}
    Sizes: box [width,height,length]; sphere [radius]; cylinder [radius,height]; cone [bottomRadius,height]; capsule [radius,height]; torus [ringRadius,pipeRadius]; pyramid [width,height,length].
    Rules: the Y axis points up. Rotation is in degrees. Center the whole object at the origin and keep it inside a cube from -1 to 1.
    Use 5 to 40 parts with sensible proportions and fitting colors. Parts must touch or overlap so nothing floats in the air.
    """
}

// MARK: JSON -> SceneKit

enum SceneBuilder {
    static func parse(_ text: String) throws -> Model3D {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { throw Model3DError.invalid }
        guard let m = try? JSONDecoder().decode(Model3D.self, from: Data(text[a...b].utf8)), !m.parts.isEmpty else {
            throw Model3DError.invalid
        }
        return m
    }

    private static func size(_ arr: [Double]?, _ i: Int, _ d: Double) -> CGFloat {
        guard let arr, arr.indices.contains(i) else { return CGFloat(d) }
        return CGFloat(min(max(arr[i], 0.01), 5))
    }

    private static func vec(_ arr: [Double]?, scale: Double = 1) -> SCNVector3 {
        func at(_ i: Int) -> Float { guard let arr, arr.indices.contains(i) else { return 0 }; return Float(arr[i] * scale) }
        return SCNVector3(at(0), at(1), at(2))
    }

    /// Scene without camera (also used for the USDZ export).
    static func scene(from m: Model3D) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.05, alpha: 1)
        for p in m.parts.prefix(60) {
            let geo: SCNGeometry
            switch p.shape.lowercased() {
            case "sphere": geo = SCNSphere(radius: size(p.size, 0, 0.3))
            case "cylinder": geo = SCNCylinder(radius: size(p.size, 0, 0.2), height: size(p.size, 1, 0.5))
            case "cone": geo = SCNCone(topRadius: 0, bottomRadius: size(p.size, 0, 0.3), height: size(p.size, 1, 0.5))
            case "capsule":
                let r = size(p.size, 0, 0.15)
                geo = SCNCapsule(capRadius: r, height: max(size(p.size, 1, 0.5), r * 2.1))
            case "torus": geo = SCNTorus(ringRadius: size(p.size, 0, 0.4), pipeRadius: size(p.size, 1, 0.1))
            case "pyramid": geo = SCNPyramid(width: size(p.size, 0, 0.5), height: size(p.size, 1, 0.5), length: size(p.size, 2, 0.5))
            default: geo = SCNBox(width: size(p.size, 0, 0.4), height: size(p.size, 1, 0.4), length: size(p.size, 2, 0.4), chamferRadius: 0)
            }
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            mat.diffuse.contents = UIColor(hex: p.color ?? "") ?? UIColor.lightGray
            mat.roughness.contents = 0.6
            mat.metalness.contents = 0.1
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            node.position = vec(p.position)
            node.eulerAngles = vec(p.rotation, scale: .pi / 180)
            scene.rootNode.addChildNode(node)
        }
        return scene
    }

    static func generate(from m: Model3D) -> Generated3D {
        let scene = scene(from: m)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 0.9, 4.2)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        return Generated3D(model: m, scene: scene, camera: camera)
    }

    /// Writes a .usdz file you can share, open in Files, and view in AR (Quick Look).
    static func exportUSDZ(_ m: Model3D) -> URL? {
        let clean = (m.name ?? "model").filter { $0.isLetter || $0.isNumber }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((clean.isEmpty ? "model" : clean) + ".usdz")
        try? FileManager.default.removeItem(at: url)
        return scene(from: m).write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }
}

extension UIColor {
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

// MARK: viewer

struct Model3DSheet: View {
    let item: Generated3D
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            SceneView(scene: item.scene, pointOfView: item.camera,
                      options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Klaar") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        if let fileURL { ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") } }
                    }
                }
                .onAppear { fileURL = SceneBuilder.exportUSDZ(item.model) }
        }
    }
}
