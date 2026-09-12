import Foundation

enum RadiometryChecks {
    struct Fixture: Decodable {
        let name: String
        let shutterOffset: Double
        let high: Bool
        let scale: Double
        let bias: Double
        let userOffset: Double
    }

    static func run(fixtures: URL) throws {
        let cases = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        var compared = 0, invalid = 0, worst = 0.0, operatingWorst = 0.0
        for fixture in cases {
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent(fixture.name + ".raw"))
            let raw = stride(from: 0, to: bytes.count, by: 2).map {
                UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
            }
            let expectedBytes = try Data(contentsOf: fixtures.appendingPathComponent(fixture.name + ".expected"))
            let expected: [Double] = expectedBytes.withUnsafeBytes { buffer in
                stride(from: 0, to: buffer.count, by: 8).map {
                    Double(bitPattern: UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt64.self)))
                }
            }
            let meta = ThermalDecoder.metadata(from: raw)
            precondition(meta.shutterRaw == raw[256 * 192 + 257])
            let table = ThermalDecoder.temperatureTable(meta: meta,
                shutterOffset: fixture.shutterOffset, userOffset: fixture.userOffset,
                range: fixture.high ? .high : .normal, scale: fixture.scale, bias: fixture.bias)!
            precondition(table.count == expected.count)
            for i in table.indices {
                if expected[i].isFinite {
                    precondition(table[i].isFinite, "\(fixture.name)[\(i)] unexpectedly invalid")
                    let error = abs(table[i] - expected[i])
                    worst = max(worst, error)
                    precondition(error < 0.1, "\(fixture.name)[\(i)] differs by \(error) C")
                    // Python uses float32. Close to zero radiance, fourth-root
                    // inversion amplifies roundoff far below the camera range.
                    let model = (expected[i] - fixture.bias - fixture.userOffset) / fixture.scale
                    if model >= -20 && model <= 450 {
                        operatingWorst = max(operatingWorst, error)
                        precondition(error < 0.002, "\(fixture.name)[\(i)] differs by \(error) C")
                    }
                    compared += 1
                } else {
                    precondition(!table[i].isFinite, "Invalid radiance became a temperature")
                    invalid += 1
                }
            }
        }
        print(String(format: "Python parity: %d valid + %d invalid entries, max difference %.6f C.",
                     compared, invalid, worst))
        print(String(format: "Maximum difference within -20...450 C model range: %.6f C.", operatingWorst))
    }
}
