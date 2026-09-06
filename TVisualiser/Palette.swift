import SwiftUI
import CoreImage
import UIKit

struct AlbumPalette {
    let vibrant: Color?
    let vibrantLight: Color?
    let vibrantDark: Color?
    let muted: Color?
    let mutedLight: Color?
    let mutedDark: Color?
    let dominant: Color?

    // MARK: - Convenience accessors
    // UI code that just wants "a" background/foreground/text color can use
    // these instead of picking a specific swatch and handling nil itself.

    var background: Color { mutedDark ?? dominant ?? muted ?? .black }
    var foreground: Color { vibrant ?? vibrantLight ?? vibrantDark ?? muted ?? .white }
    var accent: Color { vibrant ?? vibrantLight ?? vibrantDark ?? muted ?? .blue }
    
    var onAccent: Color {
        PaletteExtractor.isLight(accent) ? .black : .white
    }

    var primaryText: Color {
        PaletteExtractor.isLight(background) ? .black : .white
    }

    var secondaryText: Color {
        PaletteExtractor.isLight(background) ? Color.black.opacity(0.6) : Color.white.opacity(0.6)
    }

    static let `default` = AlbumPalette(
        vibrant: nil, vibrantLight: nil, vibrantDark: nil,
        muted: nil, mutedLight: nil, mutedDark: nil,
        dominant: nil
    )
}

enum PaletteExtractor {

    /// Extracts a full palette from `image`: Vibrant/Muted swatches (each
    /// with Light/Dark variants) plus the single most common color
    /// (`dominant`), following the same target-based scoring approach as
    /// Android's Palette API. Any swatch the image has no good candidate
    /// for comes back `nil` — use `AlbumPalette`'s convenience accessors
    /// if you just want "a" background/foreground color with fallbacks.
    static func extract(from image: UIImage, maxDimension: CGFloat = 100) -> AlbumPalette {
        guard let candidates = quantizedCandidates(from: image, maxDimension: maxDimension),
              !candidates.isEmpty else {
            return .default
        }

        let dominant = candidates.max(by: { $0.population < $1.population })?.color

        return AlbumPalette(
            vibrant: bestSwatch(from: candidates, target: .vibrant)?.color,
            vibrantLight: bestSwatch(from: candidates, target: .lightVibrant)?.color,
            vibrantDark: bestSwatch(from: candidates, target: .darkVibrant)?.color,
            muted: bestSwatch(from: candidates, target: .muted)?.color,
            mutedLight: bestSwatch(from: candidates, target: .lightMuted)?.color,
            mutedDark: bestSwatch(from: candidates, target: .darkMuted)?.color,
            dominant: dominant,
            
        )
    }

    static func isLight(_ color: Color) -> Bool {
        guard let components = UIColor(color).cgColor.components, components.count >= 3 else { return false }
        let brightness = (components[0] * 299 + components[1] * 587 + components[2] * 114) / 1000
        return brightness > 0.5
    }

    // ================================================================
    // MARK: - Candidate extraction (color quantization)
    // ================================================================

    private struct Candidate {
        let color: Color
        let population: Int
        let saturation: Float
        let lightness: Float
    }

    private static func quantizedCandidates(from image: UIImage, maxDimension: CGFloat) -> [Candidate]? {
        guard let cgImage = downsampledCGImage(from: image, maxDimension: maxDimension) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Quantize into buckets by dropping the low 4 bits of each channel
        // (16 levels/channel = 4096 buckets), while tracking each bucket's
        // real running RGB sum so we report the bucket's *actual* average
        // color rather than the quantization midpoint.
        struct Bucket {
            var rSum = 0, gSum = 0, bSum = 0, count = 0
        }
        var buckets: [Int: Bucket] = [:]

        for pixelIndex in stride(from: 0, to: pixelData.count, by: bytesPerPixel) {
            let alpha = pixelData[pixelIndex + 3]
            guard alpha > 32 else { continue } // skip near-transparent pixels

            let r = Int(pixelData[pixelIndex])
            let g = Int(pixelData[pixelIndex + 1])
            let b = Int(pixelData[pixelIndex + 2])

            // Near-black/near-white pixels are usually letterboxing or
            // borders, not meaningful palette colors — skip them.
            if (r > 245 && g > 245 && b > 245) || (r < 10 && g < 10 && b < 10) {
                continue
            }

            let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
            var bucket = buckets[key] ?? Bucket()
            bucket.rSum += r
            bucket.gSum += g
            bucket.bSum += b
            bucket.count += 1
            buckets[key] = bucket
        }

        guard !buckets.isEmpty else { return nil }

        // Bound the scoring cost to the most populous buckets.
        let topBuckets = buckets.values.sorted { $0.count > $1.count }.prefix(128)

        return topBuckets.map { bucket in
            let r = Float(bucket.rSum) / Float(bucket.count) / 255
            let g = Float(bucket.gSum) / Float(bucket.count) / 255
            let b = Float(bucket.bSum) / Float(bucket.count) / 255
            let hsl = rgbToHSL(r: r, g: g, b: b)
            return Candidate(
                color: Color(red: Double(r), green: Double(g), blue: Double(b)),
                population: bucket.count,
                saturation: hsl.s,
                lightness: hsl.l
            )
        }
    }

    private static func downsampledCGImage(from image: UIImage, maxDimension: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image.cgImage }

        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
    }

    // ================================================================
    // MARK: - Swatch target scoring
    // (Loosely follows Android's Palette API target/weight constants —
    //  a well-established approach for turning "some pixels" into a
    //  meaningful named palette rather than ad hoc region averages.)
    // ================================================================

    private struct SwatchTarget {
        let lightnessTarget: Float
        let lightnessMin: Float
        let lightnessMax: Float
        let saturationTarget: Float
        let saturationMin: Float

        static let lightVibrant = SwatchTarget(lightnessTarget: 0.74, lightnessMin: 0.55, lightnessMax: 1.0, saturationTarget: 1.0, saturationMin: 0.35)
        static let vibrant      = SwatchTarget(lightnessTarget: 0.50, lightnessMin: 0.30, lightnessMax: 0.7, saturationTarget: 1.0, saturationMin: 0.35)
        static let darkVibrant  = SwatchTarget(lightnessTarget: 0.26, lightnessMin: 0.0,  lightnessMax: 0.45, saturationTarget: 1.0, saturationMin: 0.35)
        static let lightMuted   = SwatchTarget(lightnessTarget: 0.74, lightnessMin: 0.55, lightnessMax: 1.0, saturationTarget: 0.3, saturationMin: 0.0)
        static let muted        = SwatchTarget(lightnessTarget: 0.50, lightnessMin: 0.30, lightnessMax: 0.7, saturationTarget: 0.3, saturationMin: 0.0)
        static let darkMuted    = SwatchTarget(lightnessTarget: 0.26, lightnessMin: 0.0,  lightnessMax: 0.45, saturationTarget: 0.3, saturationMin: 0.0)
    }

    private static func bestSwatch(from candidates: [Candidate], target: SwatchTarget) -> Candidate? {
        let maxPopulation = Float(candidates.map(\.population).max() ?? 1)

        let eligible = candidates.filter {
            $0.lightness >= target.lightnessMin && $0.lightness <= target.lightnessMax
        }
        guard !eligible.isEmpty else { return nil }

        return eligible.max { a, b in
            score(a, target: target, maxPopulation: maxPopulation) < score(b, target: target, maxPopulation: maxPopulation)
        }
    }

    private static func score(_ candidate: Candidate, target: SwatchTarget, maxPopulation: Float) -> Float {
        let saturationScore = 1 - abs(candidate.saturation - target.saturationTarget)
        let lightnessScore = 1 - abs(candidate.lightness - target.lightnessTarget)
        let populationScore = maxPopulation > 0 ? Float(candidate.population) / maxPopulation : 0

        let saturationWeight: Float = 0.24
        let lightnessWeight: Float = 0.52
        let populationWeight: Float = 0.24

        var total = saturationScore * saturationWeight
                  + lightnessScore * lightnessWeight
                  + populationScore * populationWeight

        // Soft penalty (not a hard exclude) for falling short of the
        // target's minimum saturation, so a vibrant target can still
        // return "the closest available" on fairly muted artwork
        // instead of coming back nil.
        if candidate.saturation < target.saturationMin {
            total *= 0.5
        }

        return total
    }

    // ================================================================
    // MARK: - RGB <-> HSL
    // ================================================================

    private struct HSL {
        let h: Float
        let s: Float
        let l: Float
    }

    private static func rgbToHSL(r: Float, g: Float, b: Float) -> HSL {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return HSL(h: 0, s: 0, l: l) }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)

        var h: Float
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6

        return HSL(h: h, s: s, l: l)
    }
}
