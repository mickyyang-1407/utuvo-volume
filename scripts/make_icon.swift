import AppKit

// 畫 App 圖示：深色圓角方塊、橫向膠囊軌道、直立的玻璃膠囊。用法：swift make_icon.swift <輸出.png>
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func grad(_ colors: [CGColor], _ rect: CGRect, vertical: Bool = true) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: vertical ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.maxY), options: [])
}
// 底
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)); ctx.clip()
grad([col(0x343764), col(0x16172a)], tile)
ctx.restoreGState()
// 軌道外框
let pill = CGRect(x: 170, y: 402, width: 684, height: 220)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: col(0x000000, 0.55))
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 110, cornerHeight: 110, transform: nil)); ctx.clip()
grad([col(0xb4b7c9), col(0x3a3c4e)], pill)
ctx.restoreGState()
// 軌道內：夜晚
let inner = pill.insetBy(dx: 20, dy: 20)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 90, cornerHeight: 90, transform: nil)); ctx.clip()
grad([col(0x32356e), col(0x1c1e40)], inner)
ctx.setFillColor(col(0x3a2a44)); ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 48))
ctx.setFillColor(col(0xf6f2cf)); ctx.fillEllipse(in: CGRect(x: 690, y: 520, width: 54, height: 54))
for (x, y, r) in [(250.0, 560.0, 5.0), (300, 520, 4), (640, 570, 4), (770, 500, 5), (600, 500, 3)] {
    ctx.setFillColor(col(0xe6eaff, 0.9)); ctx.fillEllipse(in: CGRect(x: x, y: y, width: r * 2, height: r * 2))
}
ctx.restoreGState()
// 玻璃膠囊：裡面是白天
let lens = CGRect(x: 372, y: 300, width: 200, height: 424)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: col(0x000000, 0.55))
ctx.addPath(CGPath(roundedRect: lens, cornerWidth: 100, cornerHeight: 100, transform: nil))
ctx.setFillColor(col(0x000000, 0.4)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: lens, cornerWidth: 100, cornerHeight: 100, transform: nil)); ctx.clip()
grad([col(0xd9f3fb), col(0x8fd3ee)], lens)
ctx.setFillColor(col(0xf4c39c)); ctx.fill(CGRect(x: lens.minX, y: 430, width: lens.width, height: 70))
ctx.setFillColor(col(0xcf9160)); ctx.fill(CGRect(x: lens.minX, y: lens.minY, width: lens.width, height: 132))
ctx.setFillColor(col(0xfff3a0)); ctx.fillEllipse(in: CGRect(x: 430, y: 560, width: 84, height: 84))
// 邊緣加深＋高光
let rg = CGGradient(colorsSpace: cs, colors: [col(0xffffff, 0), col(0xffffff, 0.12), col(0x1e1e3c, 0.38)] as CFArray, locations: [0.55, 0.85, 1])!
ctx.saveGState(); ctx.translateBy(x: lens.midX, y: lens.midY); ctx.scaleBy(x: 1, y: lens.height / lens.width)
ctx.drawRadialGradient(rg, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: lens.width / 2 + 6, options: [])
ctx.restoreGState()
ctx.setFillColor(col(0xffffff, 0.5)); ctx.fillEllipse(in: CGRect(x: 404, y: 640, width: 90, height: 44))
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: lens.insetBy(dx: 4, dy: 4), cornerWidth: 96, cornerHeight: 96, transform: nil))
ctx.setStrokeColor(col(0xffffff, 0.8)); ctx.setLineWidth(8); ctx.strokePath()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
