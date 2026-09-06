import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let scale = CGFloat(size)/1024
    let transform = AffineTransform(scale: scale); (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 40,y:40,width:944,height:944), xRadius:220,yRadius:220)
    NSGradient(starting: NSColor(srgbRed:0.34,green:0.28,blue:0.92,alpha:1), ending: NSColor(srgbRed:0.12,green:0.08,blue:0.35,alpha:1))!.draw(in:background,angle:60)
    for (index, height) in [180.0,320,510,380,220].enumerated() {
        NSColor.white.withAlphaComponent(index == 2 ? 1 : 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 253 + Double(index)*105, y:512-height/2, width:65,height:height), xRadius:32,yRadius:32).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("\(size).png"))
}
