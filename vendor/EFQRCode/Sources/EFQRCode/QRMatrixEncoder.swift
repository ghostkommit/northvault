import Foundation
import JavaScriptCore

// Local change: use the pinned Arase encoder instead of CoreImage rasterization.
// A fresh isolated context has no host objects, filesystem, network, or console.
// Payload bytes are arguments, never JavaScript source or exception messages.
enum QRMatrixEncoder {
    static func encode(_ data: Data, level: Int) -> [[Bool]]? {
        guard !data.isEmpty, data.count <= 1_000, (0...3).contains(level),
              let context = JSContext(),
              let function = context.evaluateScript(qrMatrixScript), context.exception == nil,
              let rows = function.call(withArguments: [Array(data), level])?.toArray() as? [[Bool]],
              context.exception == nil, (21...177).contains(rows.count),
              rows.allSatisfy({ $0.count == rows.count }) else { return nil }
        // EFQRCode expects a one-module border around its matrix.
        let border = Array(repeating: false, count: rows.count + 2)
        return [border] + rows.map { [false] + $0 + [false] } + [border]
    }
}
