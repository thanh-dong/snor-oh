import XCTest
import CoreGraphics
@testable import SnorOhSwift

/// Verifies the soft-edge background removal + color decontamination
/// in SmartImport.removeBackground.
///
/// Fixture: 40x40 RGBA image. Gray (128,128,128) background everywhere.
/// A 6x6 block in the interior is pure red (255,0,0).
/// A 1-px ring around the red block is (160,96,96) — a 25%-red / 75%-bg
/// blend that simulates the subtle anti-aliased bleed around a sprite's
/// silhouette. Its RGB-distance from bg is ~55.4, which is squarely inside
/// the [inner=25, outer=90] transition band, exercising the decontamination
/// path. (A 50/50 blend would be past the outer threshold — treated as
/// fully sprite, no decontamination needed.)
final class SmartImportBgRemovalTests: XCTestCase {

    private struct Fixture {
        let image: CGImage
        let bgColor: SmartImport.BgColor
        let cornerXY: (Int, Int)       // pure bg
        let interiorXY: (Int, Int)     // pure red
        let edgeXY: (Int, Int)         // 50/50 blend of red + bg
    }

    private func makeFixture() -> Fixture {
        let w = 40, h = 40
        let ctx = SmartImport.createRGBAContext(width: w, height: h)!
        let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow

        // Write raw bytes to bypass CGColor's color-management path.
        // The context is premultipliedLast with DeviceRGB; at alpha 255,
        // premultiplied == straight, so these bytes are the final state.
        func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
            let off = y * bytesPerRow + x * 4
            pixels[off]     = r
            pixels[off + 1] = g
            pixels[off + 2] = b
            pixels[off + 3] = a
        }

        // Bg gray (128,128,128) everywhere.
        for y in 0..<h {
            for x in 0..<w {
                put(x, y, 128, 128, 128)
            }
        }

        // Interior pure red: 6x6 block at (17..22, 17..22).
        for y in 17..<23 {
            for x in 17..<23 {
                put(x, y, 255, 0, 0)
            }
        }

        // Edge ring: 1-px frame, 25%-red / 75%-bg blend = (160, 96, 96).
        // Distance to bg ≈ 55.4, inside the [25, 90] transition band.
        for x in 16..<24 { put(x, 16, 160, 96, 96); put(x, 23, 160, 96, 96) }
        for y in 17..<23 { put(16, y, 160, 96, 96); put(23, y, 160, 96, 96) }

        let img = ctx.makeImage()!
        return Fixture(
            image: img,
            bgColor: SmartImport.BgColor(r: 128, g: 128, b: 128),
            cornerXY: (1, 1),
            interiorXY: (20, 20),
            edgeXY: (16, 17)
        )
    }

    /// Read a pixel from the returned context's memory (top-left origin).
    private func readPixel(_ ctx: CGContext, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let off = y * ctx.bytesPerRow + x * 4
        return (px[off], px[off + 1], px[off + 2], px[off + 3])
    }

    func testCornerBecomesTransparent() throws {
        let f = makeFixture()
        let (ctx, _) = SmartImport.removeBackground(from: f.image, bgColor: f.bgColor)!
        let (r, g, b, a) = readPixel(ctx, x: f.cornerXY.0, y: f.cornerXY.1)
        XCTAssertEqual(a, 0, "corner bg pixel should be fully transparent")
        XCTAssertEqual(r, 0); XCTAssertEqual(g, 0); XCTAssertEqual(b, 0)
    }

    func testInteriorStaysFullyOpaqueRed() throws {
        let f = makeFixture()
        let (ctx, _) = SmartImport.removeBackground(from: f.image, bgColor: f.bgColor)!
        let (r, g, b, a) = readPixel(ctx, x: f.interiorXY.0, y: f.interiorXY.1)
        XCTAssertEqual(a, 255, "interior pure-red pixel must remain opaque")
        XCTAssertGreaterThanOrEqual(r, 250)
        XCTAssertLessThanOrEqual(g, 5)
        XCTAssertLessThanOrEqual(b, 5)
    }

    /// The edge pixel (160, 96, 96) is a 25%-red / 75%-bg blend — exactly
    /// the kind of pixel that produces the halo. The new code must:
    ///   (a) give it partial alpha (0 < a < 255), and
    ///   (b) decontaminate its straight RGB so it swings toward red and
    ///       away from gray. We check direction rather than exact recovery
    ///       (perfect recovery would require knowing the true blend alpha).
    func testEdgeRingIsDecontaminated() throws {
        let f = makeFixture()
        let (ctx, _) = SmartImport.removeBackground(from: f.image, bgColor: f.bgColor)!
        let (r, g, b, a) = readPixel(ctx, x: f.edgeXY.0, y: f.edgeXY.1)

        XCTAssertGreaterThan(a, 0, "edge pixel should not be fully transparent")
        XCTAssertLessThan(a, 255, "edge pixel should not be fully opaque — must fall in transition band")

        // Unpremultiply to recover the straight color the renderer will see.
        let aF = Double(a) / 255.0
        let straightR = Double(r) / aF
        let straightG = Double(g) / aF
        let straightB = Double(b) / aF

        XCTAssertGreaterThan(straightR, 160, "decontaminated R should move above the 160 blend value toward pure red")
        XCTAssertLessThan(straightG, 96, "decontaminated G should drop below the 96 blend value toward 0")
        XCTAssertLessThan(straightB, 96, "decontaminated B should drop below the 96 blend value toward 0")
    }
}
