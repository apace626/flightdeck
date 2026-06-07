import AppKit

// Renders a 1024×1024 Flightdeck app icon: the signature split layout
// (left pane + two stacked right panes) in Catppuccin colors on a dark squircle.

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// Background squircle with margin (macOS icon grid leaves ~10% padding).
let margin = size * 0.085
let bgRect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let bgRadius = bgRect.width * 0.2237
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

// Dark gradient base (#181825 → #1e1e2e), top-down.
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(24, 24, 37).cgColor, color(30, 30, 46).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
// Subtle mauve glow, upper-left.
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(203, 166, 247).withAlphaComponent(0.28).cgColor,
             color(203, 166, 247).withAlphaComponent(0).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(glow,
    startCenter: CGPoint(x: size * 0.32, y: size * 0.72), startRadius: 0,
    endCenter: CGPoint(x: size * 0.32, y: size * 0.72), endRadius: size * 0.5, options: [])
ctx.restoreGState()

// Inner "screen" the panes sit on.
let inset = bgRect.insetBy(dx: bgRect.width * 0.16, dy: bgRect.width * 0.16)
let tile = inset.width * 0.07
func paneRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: inset.minX + x, y: inset.minY + y, width: w, height: h)
}
func drawPane(_ rect: CGRect, _ c: NSColor) {
    let r = rect.width * 0.12
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(r, rect.height * 0.12),
                       cornerHeight: min(r, rect.height * 0.12), transform: nil))
    ctx.setFillColor(c.cgColor)
    ctx.fillPath()
}

let gap = inset.width * 0.05
let leftW = inset.width * 0.54
let rightW = inset.width - leftW - gap
let fullH = inset.height
let rightH = (fullH - gap) / 2

// Left tall pane (blue), right top (green), right bottom (pink) — the layout motif.
drawPane(paneRect(0, 0, leftW, fullH), color(137, 180, 250))
drawPane(paneRect(leftW + gap, fullH - rightH, rightW, rightH), color(166, 227, 161))
drawPane(paneRect(leftW + gap, 0, rightW, rightH), color(243, 139, 168))

// A terminal prompt "❯_" on the left pane.
let prompt = "❯"
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: leftW * 0.42, weight: .bold),
    .foregroundColor: color(30, 30, 46),
]
let ps = NSAttributedString(string: prompt, attributes: attrs)
let psSize = ps.size()
ps.draw(at: NSPoint(x: inset.minX + leftW * 0.22,
                    y: inset.minY + fullH * 0.5 - psSize.height * 0.5))
// Blinking cursor block next to it.
let curW = leftW * 0.16
let cur = CGRect(x: inset.minX + leftW * 0.22 + psSize.width + leftW * 0.06,
                 y: inset.minY + fullH * 0.5 - psSize.height * 0.30,
                 width: curW, height: psSize.height * 0.6)
ctx.addPath(CGPath(roundedRect: cur, cornerWidth: curW * 0.2, cornerHeight: curW * 0.2, transform: nil))
ctx.setFillColor(color(30, 30, 46).cgColor)
ctx.fillPath()

image.unlockFocus()

// Write PNG.
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/flightdeck-icon.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
