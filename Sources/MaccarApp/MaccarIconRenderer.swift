import Foundation
import AppKit

@MainActor
public enum MaccarIconRenderer {

    /// Renders a native vector 18x18 monochrome template icon for NSStatusItem.
    /// When isTemplate = true, macOS handles Dark / Light menu bar adaptation automatically.
    public static func renderMenuBarIcon(connected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            ctx.saveGState()

            // Draw Display (Master Screen)
            let displayRect = CGRect(x: 2.0, y: 4.5, width: 9.5, height: 7.5)
            let displayPath = CGPath(roundedRect: displayRect, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)
            ctx.addPath(displayPath)
            ctx.setLineWidth(1.2)
            ctx.strokePath()

            // Display stand
            ctx.move(to: CGPoint(x: 6.75, y: 4.5))
            ctx.addLine(to: CGPoint(x: 6.75, y: 2.5))
            ctx.move(to: CGPoint(x: 4.5, y: 2.5))
            ctx.addLine(to: CGPoint(x: 9.0, y: 2.5))
            ctx.strokePath()

            // Draw iPad (Companion Screen)
            let ipadRect = CGRect(x: 10.5, y: 5.5, width: 5.5, height: 8.5)
            let ipadPath = CGPath(roundedRect: ipadRect, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)
            ctx.addPath(ipadPath)
            ctx.setLineWidth(1.1)
            ctx.strokePath()

            // Home / Dynamic Island indicator on iPad
            ctx.move(to: CGPoint(x: 12.5, y: 12.8))
            ctx.addLine(to: CGPoint(x: 14.0, y: 12.8))
            ctx.strokePath()

            // Connection indicator dot (Top-right of iPad if connected)
            if connected {
                let dotRect = CGRect(x: 13.5, y: 13.5, width: 3.5, height: 3.5)
                ctx.addEllipse(in: dotRect)
                ctx.fillPath()
            }

            ctx.restoreGState()
            return true
        }

        image.isTemplate = true
        return image
    }

    /// Renders a full-color high-resolution vector App Icon.
    public static func renderAppIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Balanced with the `restoreGState` below. Leaving this unmatched pops the state of
            // whatever context is drawing the image — during a PDF capture that discards every
            // view drawn after the icon.
            ctx.saveGState()

            let s = size

            // 1. Background squircle with macOS dark slate gradient
            let rect = bounds.insetBy(dx: s * 0.04, dy: s * 0.04)
            let squirclePath = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)

            let bgGrad = NSGradient(
                starting: NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0),
                ending: NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1.0)
            )
            bgGrad?.draw(in: squirclePath, angle: -90)

            // 2. Subtle internal glow
            NSColor(white: 1.0, alpha: 0.12).setStroke()
            squirclePath.lineWidth = s * 0.015
            squirclePath.stroke()

            // 3. Mac Mini base silhouette (silver aluminum metallic)
            let macMiniRect = CGRect(x: s * 0.18, y: s * 0.22, width: s * 0.38, height: s * 0.12)
            let macPath = NSBezierPath(roundedRect: macMiniRect, xRadius: s * 0.03, yRadius: s * 0.03)
            NSColor(red: 0.75, green: 0.77, blue: 0.82, alpha: 1.0).setFill()
            macPath.fill()

            // Power LED dot on Mac mini
            let ledRect = CGRect(x: s * 0.50, y: s * 0.265, width: s * 0.02, height: s * 0.02)
            NSColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: ledRect).fill()

            // 4. iPad tablet display (standing tall on right)
            let ipadRect = CGRect(x: s * 0.46, y: s * 0.30, width: s * 0.36, height: s * 0.48)
            let ipadPath = NSBezierPath(roundedRect: ipadRect, xRadius: s * 0.04, yRadius: s * 0.04)
            NSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0).setFill()
            ipadPath.fill()

            // iPad Screen (Cyan/Purple gradient glow)
            let screenRect = ipadRect.insetBy(dx: s * 0.025, dy: s * 0.03)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: s * 0.025, yRadius: s * 0.025)
            let screenGrad = NSGradient(
                starting: NSColor(red: 0.10, green: 0.60, blue: 0.95, alpha: 0.9),
                ending: NSColor(red: 0.30, green: 0.25, blue: 0.85, alpha: 0.9)
            )
            screenGrad?.draw(in: screenPath, angle: 45)

            // 5. Connection beam / bridge linking Mac mini to iPad
            NSColor(red: 0.2, green: 0.85, blue: 1.0, alpha: 0.8).setStroke()
            let beam = NSBezierPath()
            beam.lineWidth = s * 0.02
            beam.move(to: CGPoint(x: s * 0.37, y: s * 0.34))
            beam.curve(to: CGPoint(x: s * 0.46, y: s * 0.45), controlPoint1: CGPoint(x: s * 0.37, y: s * 0.42), controlPoint2: CGPoint(x: s * 0.42, y: s * 0.45))
            beam.stroke()

            ctx.restoreGState()
            return true
        }

        return image
    }
}
