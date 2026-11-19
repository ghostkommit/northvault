import AppKit

// Offline rasterization of the supplied SVG, preserving its paths and gradients.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: source),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
    fatalError("Could not rasterize the app logo")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
