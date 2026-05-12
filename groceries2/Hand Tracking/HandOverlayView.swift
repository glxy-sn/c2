import SwiftUI
import Vision

// MARK: - HandOverlayView
//
// Coordinate conversion (from article):
//   Vision normalized coords:  (0,0) = bottom-left, (1,1) = top-right
//   Screen/SwiftUI coords:     (0,0) = top-left
//
// The article's convertVisionPoint swaps x/y axes:
//   screenX = visionY * screenWidth
//   screenY = visionX * screenHeight
//
// This accounts for how AVFoundation feeds portrait frames to Vision
// when orientation is set to .up — the x and y axes are transposed
// relative to what appears on screen.

struct HandOverlayView: View {
    let landmarks: HandLandmarks?
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            guard let lm = landmarks else { return }

            // Build an ordered array of optional screen points
            // Index matches HandLandmarks.orderedJoints
            let screenPoints: [CGPoint?] = HandLandmarks.orderedJoints.map { joint in
                guard let vp = lm.points[joint] else { return nil }
                return convertVisionPoint(vp, to: size)
            }

            // ── 1. Palm fill polygon (wrist → knuckles) ──────────────────
            let palmIndices = [0, 5, 9, 13, 17, 1]  // wrist + 4 knuckles + thumbCMC, close loop
            let palmPts = palmIndices.compactMap { screenPoints[$0] }
            if palmPts.count == palmIndices.count {
                var palmPath = Path()
                palmPath.move(to: palmPts[0])
                palmPts.dropFirst().forEach { palmPath.addLine(to: $0) }
                palmPath.closeSubpath()
                ctx.fill(palmPath, with: .color(.cyan.opacity(0.10)))
            }

            // ── 2. Wrist → first knuckle of each finger ───────────────────
            if let wrist = screenPoints[0] {
                for knuckleIdx in HandLandmarks.wristToKnuckle {
                    guard let knuckle = screenPoints[knuckleIdx] else { continue }
                    var path = Path()
                    path.move(to: wrist)
                    path.addLine(to: knuckle)
                    ctx.stroke(path, with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }

            // ── 3. Palm cross (knuckle ↔ knuckle) ────────────────────────
            for (a, b) in HandLandmarks.palmCross {
                guard let ptA = screenPoints[a], let ptB = screenPoints[b] else { continue }
                var path = Path()
                path.move(to: ptA)
                path.addLine(to: ptB)
                ctx.stroke(path, with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }

            // ── 4. Finger bone segments ───────────────────────────────────
            for (a, b) in HandLandmarks.fingerSegments {
                guard let ptA = screenPoints[a], let ptB = screenPoints[b] else { continue }
                var path = Path()
                path.move(to: ptA)
                path.addLine(to: ptB)
                ctx.stroke(path, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // ── 5. Landmark dots ──────────────────────────────────────────
            let tipIndices: Set<Int> = [4, 8, 12, 16, 20]

            for (i, joint) in HandLandmarks.orderedJoints.enumerated() {
                guard let pt = screenPoints[i] else { continue }

                let isWrist = (joint == .wrist)
                let isTip   = tipIndices.contains(i)

                let radius: CGFloat = isWrist ? 7 : (isTip ? 5.5 : 4)
                let dotColor: Color = isWrist ? .green : (isTip ? .yellow : .white)

                let rect = CGRect(x: pt.x - radius, y: pt.y - radius,
                                  width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(dotColor))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.black.opacity(0.45)),
                           lineWidth: 1.2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate Conversion
    //
    // Vision normalized coords:  (0,0) = bottom-left, (1,1) = top-right
    // Screen/SwiftUI coords:     (0,0) = top-left,    (W,H) = bottom-right
    //
    // Camera feed portrait = 1080×1920 (aspect 9:16 = 0.5625).
    // AVCaptureVideoPreviewLayer uses .resizeAspectFill → scales image to
    // fill the view completely, then crops the excess.
    // Vision coords map to the FULL uncropped image, so we must compensate
    // for the crop offset to align landmarks with the visible preview.

    private func convertVisionPoint(_ vp: CGPoint, to screenSize: CGSize) -> CGPoint {
        let cameraAspect: CGFloat = 9.0 / 16.0  // portrait: 1080/1920
        let viewAspect = screenSize.width / screenSize.height

        let scaledW: CGFloat
        let scaledH: CGFloat

        if viewAspect > cameraAspect {
            // View wider than camera → scale to match width, crop height
            scaledW = screenSize.width
            scaledH = screenSize.width / cameraAspect
        } else {
            // View taller than camera → scale to match height, crop width
            scaledW = screenSize.height * cameraAspect
            scaledH = screenSize.height
        }

        let offsetX = (scaledW - screenSize.width) / 2
        let offsetY = (scaledH - screenSize.height) / 2

        return CGPoint(
            x: vp.x * scaledW - offsetX,
            y: (1 - vp.y) * scaledH - offsetY
        )
    }
}
