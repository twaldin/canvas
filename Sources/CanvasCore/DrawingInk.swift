import CoreGraphics
import Foundation

// Variable-width ink outlines, ported from perfect-freehand 1.2 (getStrokePoints +
// getStrokeOutlinePoints) by Steve Ruiz:
//
//   MIT License
//   Copyright (c) 2021 Stephen Ruiz Ltd
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
//   and associated documentation files (the "Software"), to deal in the Software without
//   restriction, including without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
//   Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
//   BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
//   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// Turns captured ink points into a closed polygon outlining a pressure-sensitive stroke.
public enum DrawingInk {
    public struct Options: Sendable {
        /// Diameter at half pressure.
        public var size: CGFloat = DrawingGeometry.inkSize
        /// How much pressure narrows the stroke (0 = constant width).
        public var thinning: CGFloat = 0.5
        /// Minimum spacing of outline points, as a fraction of `size`.
        public var smoothing: CGFloat = 0.5
        /// How strongly input points are pulled toward the previous point.
        public var streamline: CGFloat = 0.5
        /// Derive pressure from speed; set false when points carry real pressure.
        public var simulatePressure = true
        /// The stroke is finished (the last point is used as-is).
        public var complete = true

        public init() {}
    }

    struct StrokePoint {
        var point: CGPoint
        var pressure: CGFloat
        var vector: CGPoint
        var distance: CGFloat
        var runningLength: CGFloat
    }

    static let rateOfPressureChange: CGFloat = 0.275
    static let fixedPi = CGFloat.pi + 0.0001

    /// Options for these points: real pressure turns off simulation.
    public static func options(for points: [InkPoint]) -> Options {
        var options = Options()
        options.simulatePressure = !points.contains { $0.pressure != nil }
        return options
    }

    /// Closed outline polygon (implicitly closed; the last point connects to the first). Never
    /// empty for a non-empty input: a single point becomes a round dot.
    public static func outline(_ points: [InkPoint], options: Options? = nil) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        let options = options ?? Self.options(for: points)
        return outlinePoints(strokePoints(points, options), options)
    }

    static func strokePoints(_ input: [InkPoint], _ options: Options) -> [StrokePoint] {
        let t = 0.15 + (1 - options.streamline) * 0.85
        var pts: [(CGPoint, CGFloat)] = input.map { (CGPoint(x: $0.x, y: $0.y), CGFloat($0.pressure ?? 0.5)) }
        if pts.count == 2 {
            let last = pts[1]
            pts = [pts[0]]
            for i in 1..<5 {
                pts.append((lerp(pts[0].0, last.0, CGFloat(i) / 4), last.1))
            }
        }
        if pts.count == 1 {
            pts.append((CGPoint(x: pts[0].0.x + 1, y: pts[0].0.y + 1), pts[0].1))
        }
        var result = [StrokePoint(point: pts[0].0, pressure: pts[0].1 >= 0 ? pts[0].1 : 0.25, vector: CGPoint(x: 1, y: 1), distance: 0, runningLength: 0)]
        var reachedMinLength = false
        var runningLength: CGFloat = 0
        var previous = result[0]
        let maxIndex = pts.count - 1
        for i in 1..<pts.count {
            let point = options.complete && i == maxIndex ? pts[i].0 : lerp(previous.point, pts[i].0, t)
            if point == previous.point { continue }
            let distance = hypot(point.x - previous.point.x, point.y - previous.point.y)
            runningLength += distance
            if i < maxIndex && !reachedMinLength {
                if runningLength < options.size { continue }
                reachedMinLength = true
            }
            previous = StrokePoint(point: point, pressure: pts[i].1, vector: unit(sub(previous.point, point)), distance: distance, runningLength: runningLength)
            result.append(previous)
        }
        result[0].vector = result.count > 1 ? result[1].vector : .zero
        return result
    }

    static func radius(_ options: Options, pressure: CGFloat) -> CGFloat {
        options.size * (0.5 - options.thinning * (0.5 - pressure))
    }

    static func outlinePoints(_ points: [StrokePoint], _ options: Options) -> [CGPoint] {
        let size = options.size
        let totalLength = points[points.count - 1].runningLength
        let minDistance = pow(size * options.smoothing, 2)
        var left: [CGPoint] = []
        var right: [CGPoint] = []

        var prevPressure = points.prefix(10).reduce(points[0].pressure) { acc, current in
            var pressure = current.pressure
            if options.simulatePressure {
                let sp = min(1, current.distance / size)
                let rp = min(1, 1 - sp)
                pressure = min(1, acc + (rp - acc) * (sp * rateOfPressureChange))
            }
            return (acc + pressure) / 2
        }
        var radius = Self.radius(options, pressure: points[points.count - 1].pressure)
        var firstRadius: CGFloat?
        var prevVector = points[0].vector
        var pl = points[0].point
        var pr = pl
        var tl = pl
        var tr = pr
        var prevWasSharpCorner = false

        for i in 0..<points.count {
            var pressure = points[i].pressure
            let point = points[i].point
            let vector = points[i].vector
            let distance = points[i].distance
            let runningLength = points[i].runningLength
            if i < points.count - 1 && totalLength - runningLength < 3 { continue }

            if options.thinning != 0 {
                if options.simulatePressure {
                    let sp = min(1, distance / size)
                    let rp = min(1, 1 - sp)
                    pressure = min(1, prevPressure + (rp - prevPressure) * (sp * rateOfPressureChange))
                }
                radius = Self.radius(options, pressure: pressure)
            } else {
                radius = size / 2
            }
            if firstRadius == nil { firstRadius = radius }
            radius = max(0.01, radius)

            let nextVector = (i < points.count - 1 ? points[i + 1] : points[i]).vector
            let nextDot = i < points.count - 1 ? dot(vector, nextVector) : 1
            let prevDot = dot(vector, prevVector)
            let isSharpCorner = prevDot < 0 && !prevWasSharpCorner
            let nextIsSharpCorner = nextDot < 0

            if isSharpCorner || nextIsSharpCorner {
                let offset = mul(perpendicular(prevVector), radius)
                var step: CGFloat = 0
                while step < 1 {
                    tl = rotate(sub(point, offset), around: point, by: fixedPi * step)
                    left.append(tl)
                    tr = rotate(add(point, offset), around: point, by: fixedPi * -step)
                    right.append(tr)
                    step += 1 / 13
                }
                pl = tl
                pr = tr
                if nextIsSharpCorner { prevWasSharpCorner = true }
                continue
            }
            prevWasSharpCorner = false

            if i == points.count - 1 {
                let offset = mul(perpendicular(vector), radius)
                left.append(sub(point, offset))
                right.append(add(point, offset))
                continue
            }

            let offset = mul(perpendicular(lerp(nextVector, vector, nextDot)), radius)
            tl = sub(point, offset)
            if i <= 1 || distanceSquared(pl, tl) > minDistance {
                left.append(tl)
                pl = tl
            }
            tr = add(point, offset)
            if i <= 1 || distanceSquared(pr, tr) > minDistance {
                right.append(tr)
                pr = tr
            }
            prevPressure = pressure
            prevVector = vector
        }

        let firstPoint = points[0].point
        let lastPoint = points.count > 1 ? points[points.count - 1].point : add(points[0].point, CGPoint(x: 1, y: 1))

        if points.count == 1 || left.isEmpty || right.isEmpty {
            // A dot: a circle around the first point.
            let dotRadius = firstRadius ?? radius
            let start = project(firstPoint, unit(perpendicular(sub(firstPoint, lastPoint))), -dotRadius)
            var dot: [CGPoint] = []
            var step: CGFloat = 1 / 13
            while step <= 1 {
                dot.append(rotate(start, around: firstPoint, by: fixedPi * 2 * step))
                step += 1 / 13
            }
            return dot
        }

        var startCap: [CGPoint] = []
        var step: CGFloat = 0
        while step <= 1 {
            startCap.append(rotate(right[0], around: firstPoint, by: fixedPi * step))
            step += 1 / 13
        }
        var endCap: [CGPoint] = []
        let direction = perpendicular(neg(points[points.count - 1].vector))
        let endStart = project(lastPoint, direction, radius)
        step = 1 / 29
        while step < 1 {
            endCap.append(rotate(endStart, around: lastPoint, by: fixedPi * 3 * step))
            step += 1 / 29
        }
        return left + endCap + right.reversed() + startCap
    }

    // MARK: Vector helpers

    static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func mul(_ a: CGPoint, _ n: CGFloat) -> CGPoint { CGPoint(x: a.x * n, y: a.y * n) }
    static func neg(_ a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    static func perpendicular(_ a: CGPoint) -> CGPoint { CGPoint(x: a.y, y: -a.x) }
    static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat { pow(a.x - b.x, 2) + pow(a.y - b.y, 2) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { add(a, mul(sub(b, a), t)) }
    static func project(_ a: CGPoint, _ b: CGPoint, _ c: CGFloat) -> CGPoint { add(a, mul(b, c)) }

    static func unit(_ a: CGPoint) -> CGPoint {
        let length = hypot(a.x, a.y)
        return length > 0 ? CGPoint(x: a.x / length, y: a.y / length) : .zero
    }

    static func rotate(_ a: CGPoint, around c: CGPoint, by r: CGFloat) -> CGPoint {
        let s = sin(r)
        let co = cos(r)
        let px = a.x - c.x
        let py = a.y - c.y
        return CGPoint(x: px * co - py * s + c.x, y: px * s + py * co + c.y)
    }
}
