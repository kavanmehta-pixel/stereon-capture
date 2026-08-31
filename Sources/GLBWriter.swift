import Foundation
import simd

/// Minimal binary glTF 2.0 writer: one mesh, POSITION + NORMAL + uint32 indices,
/// flat grey double-sided material. Matches what the Stereon Item Library ingests.
enum GLBWriter {
    static func encode(vertices: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) -> Data {
        var bin = Data()

        var lo = vertices.first ?? .zero
        var hi = lo
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }

        let positionOffset = bin.count
        for v in vertices {
            var t = (v.x, v.y, v.z)
            withUnsafeBytes(of: &t) { bin.append(contentsOf: $0) }
        }
        let positionLength = bin.count - positionOffset

        let normalOffset = bin.count
        for n in normals {
            var t = (n.x, n.y, n.z)
            withUnsafeBytes(of: &t) { bin.append(contentsOf: $0) }
        }
        let normalLength = bin.count - normalOffset

        let indexOffset = bin.count
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        let indexLength = bin.count - indexOffset
        while bin.count % 4 != 0 { bin.append(0) }

        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "StereonCapture"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "scan"]],
            "meshes": [[
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1],
                    "indices": 2,
                    "material": 0,
                    "mode": 4,
                ]],
            ]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.72, 0.72, 0.75, 1.0],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.9,
                ],
                "doubleSided": true,
            ]],
            "accessors": [
                [
                    "bufferView": 0, "componentType": 5126, "count": vertices.count,
                    "type": "VEC3",
                    "min": [Double(lo.x), Double(lo.y), Double(lo.z)],
                    "max": [Double(hi.x), Double(hi.y), Double(hi.z)],
                ],
                ["bufferView": 1, "componentType": 5126, "count": normals.count, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5125, "count": indices.count, "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": positionOffset, "byteLength": positionLength, "target": 34962],
                ["buffer": 0, "byteOffset": normalOffset, "byteLength": normalLength, "target": 34962],
                ["buffer": 0, "byteOffset": indexOffset, "byteLength": indexLength, "target": 34963],
            ],
            "buffers": [["byteLength": bin.count]],
        ]

        var jsonData = try! JSONSerialization.data(withJSONObject: gltf, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        var out = Data()
        func appendUInt32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
        }
        appendUInt32(0x46546C67)
        appendUInt32(2)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        appendUInt32(UInt32(jsonData.count))
        appendUInt32(0x4E4F534A)
        out.append(jsonData)
        appendUInt32(UInt32(bin.count))
        appendUInt32(0x004E4942)
        out.append(bin)
        return out
    }
}
