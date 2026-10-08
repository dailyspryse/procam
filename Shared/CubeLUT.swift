import Foundation

/// A 3D LUT in Adobe/Resolve `.cube` format.
struct CubeLUT {
    let title: String
    let size: Int
    /// RGBA floats, red fastest, then green, then blue — the order `.cube`
    /// files list entries in, and the order a 3D texture's bytes are laid out.
    let rgba: [Float]

    enum ParseError: LocalizedError {
        case noSize, unsupported1D, wrongCount(expected: Int, got: Int), badLine(Int)

        var errorDescription: String? {
            switch self {
            case .noSize: return "LUT_3D_SIZE fehlt"
            case .unsupported1D: return "1D-LUTs werden nicht unterstützt"
            case let .wrongCount(e, g): return "Erwartet \(e) Einträge, gefunden \(g)"
            case let .badLine(n): return "Zeile \(n) ist ungültig"
            }
        }
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var title = ""
        var size = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        var lineNo = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }

            switch head {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                size = Int(parts.dropFirst().first ?? "") ?? 0
                values.reserveCapacity(size * size * size * 4)
            case "LUT_1D_SIZE":
                throw ParseError.unsupported1D
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                continue
            default:
                guard parts.count >= 3,
                      let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2])
                else {
                    // Unknown keywords are tolerated; malformed numbers are not.
                    if head.first?.isLetter == true { continue }
                    throw ParseError.badLine(lineNo)
                }
                values.append(contentsOf: [r, g, b, 1])
            }
        }

        guard size >= 2 else { throw ParseError.noSize }
        let expected = size * size * size
        guard values.count / 4 == expected else {
            throw ParseError.wrongCount(expected: expected, got: values.count / 4)
        }

        // Normalise output values to 0…1 if the file declares another domain.
        if domainMin.count == 3, domainMax.count == 3,
           domainMin != [0, 0, 0] || domainMax != [1, 1, 1] {
            for i in stride(from: 0, to: values.count, by: 4) {
                for c in 0..<3 {
                    let span = max(domainMax[c] - domainMin[c], 1e-6)
                    values[i + c] = (values[i + c] - domainMin[c]) / span
                }
            }
        }

        return CubeLUT(title: title, size: size, rgba: values)
    }
}
