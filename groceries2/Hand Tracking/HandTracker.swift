import Vision
import CoreGraphics
import Foundation
import QuartzCore

// MARK: - Hand Action

enum HandAction: Equatable {
    case approachingBasket   // PUT — barang masuk trolley
    case leavingBasket       // TAKE — barang keluar trolley
    case idle
}

// MARK: - HandLandmarks

struct HandLandmarks {
    let points: [VNHumanHandPoseObservation.JointName: CGPoint]

    static let orderedJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP,  .ringPIP,  .ringDIP,  .ringTip,
        .littleMCP,.littlePIP,.littleDIP,.littleTip
    ]
    static let fingerSegments: [(Int, Int)] = [
        (1,2),(2,3),(3,4),(5,6),(6,7),(7,8),
        (9,10),(10,11),(11,12),(13,14),(14,15),(15,16),(17,18),(18,19),(19,20)
    ]
    static let wristToKnuckle: [Int] = [1, 5, 9, 13, 17]
    static let palmCross: [(Int, Int)] = [(5,9),(9,13),(13,17)]

    // Bounding-box area dari semua landmark — makin besar = makin dekat kamera
    var palmArea: CGFloat {
        let pts = Array(points.values)
        guard pts.count >= 3 else { return 0 }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return (maxX - minX) * (maxY - minY)
    }
}

// MARK: - Gesture State Machine
//
// Kamera di pegangan trolley, nghadap bawah ke dalam trolley.
//
//   palmArea BESAR  = tangan DEKAT kamera (di atas trolley)
//   palmArea KECIL  = tangan JAUH/di dalam trolley
//
// ─────────────────────────────────────────────────────────────────
//  PUT sequence:
//    1. Tangan BESAR di frame + ada produk   → rekam peakArea & hadProduct=true
//    2. Tangan MENGECIL (< peak * shrinkRatio) → masuk trolley (deep)
//    3. Tangan MEMBESAR lagi (> trough * growRatio) + TIDAK ada produk
//       → produk dilepas di trolley → fire .approachingBasket
//
//  TAKE sequence:
//    1. Tangan BESAR di frame + TIDAK ada produk → rekam peakArea & hadProduct=false
//    2. Tangan MENGECIL → masuk trolley untuk ambil barang
//    3. Tangan MEMBESAR lagi + ADA produk
//       → produk diambil dari trolley → fire .leavingBasket
//
//  Kondisi sama sebelum & sesudah → reset, tidak fire
// ─────────────────────────────────────────────────────────────────

private enum GesturePhase: CustomStringConvertible {
    case idle
    // Tangan besar terdeteksi, simpan snapshot
    case large(peakArea: CGFloat, hadProduct: Bool)
    // Tangan sudah mengecil (masuk trolley), tunggu membesar lagi
    case small(troughArea: CGFloat, hadProduct: Bool)

    var description: String {
        switch self {
        case .idle:                          return "idle"
        case .large(let a, let p):           return String(format: "large(%.3f,prod=%@)", a, p ? "Y" : "N")
        case .small(let a, let p):           return String(format: "small(%.3f,prod=%@)", a, p ? "Y" : "N")
        }
    }
}

// MARK: - HandTracker

final class HandTracker {

    // MARK: - Config

    var confidenceThreshold: Float = 0.1

    /// Tangan dianggap "besar/dekat kamera" kalau area >= largeAreaThreshold.
    /// Default 0.01 untuk lebih mudah trigger (lower threshold).
    /// Lihat nilai "area" di debug panel saat tangan penuh di atas trolley.
    var largeAreaThreshold: CGFloat = 0.01

    /// Tangan dianggap "sudah masuk trolley" kalau area turun ke
    /// currentPeak * shrinkRatio. 0.3 = harus turun 70% dari peak (lebih mudah).
    var shrinkRatio: CGFloat = 0.3

    /// Tangan dianggap "sudah keluar trolley" kalau area naik ke
    /// currentTrough * growRatio. 1.5 = harus naik 50% dari trough (lebih mudah).
    var growRatio: CGFloat = 1.5

    /// Minimum frame di fase "small" sebelum return dianggap valid.
    /// 3 = ~0.1s @ 30fps (sangat responsive untuk natural gesture).
    var minSmallFrames: Int = 3

    /// Max frames missing before full phase reset.
    /// At 30fps, 50 frames ≈ 1.67 seconds.
    /// Increased from 20 to allow temporary pose detection failures without resetting gesture state.
    var maxMissingFrames: Int = 50

    // MARK: - Callbacks

    var onAction:        ((HandAction) -> Void)?
    var onWristPosition: ((CGFloat) -> Void)?
    var onLandmarks:     ((HandLandmarks?) -> Void)?

    /// Debug: (phaseDesc, palmArea, hasProduct) — set nil di production
    var onDebug: ((String, CGFloat, Bool) -> Void)?

    /// Diupdate dari CameraView setiap frame
    var hasProductInFrame: Bool = false

    // MARK: - Private state

    private var phase:         GesturePhase = .idle
    private var smallFrames:   Int          = 0
    private var missingFrames: Int          = 0

    // EMA smoothing untuk palmArea — mengurangi noise per frame
    // Alpha 0.4 = 40% weight current, 60% history
    // Smooth enough to reduce jitter, responsive enough for gesture detection
    private var smoothedArea: CGFloat = 0
    private let emaAlpha: CGFloat     = 0.4

    // MARK: - Process Frame

    func process(observations: [VNHumanHandPoseObservation]) {
        guard let obs = observations.first else {
            missingFrames += 1
            if missingFrames > maxMissingFrames { 
                resetPhase()
                print("[HandTracker] 🔄 Phase reset due to missing frames (\(missingFrames) > \(maxMissingFrames))")
            }
            onLandmarks?(nil)
            return
        }
        missingFrames = 0

        guard let wristPt = try? obs.recognizedPoint(.wrist),
              wristPt.confidence > confidenceThreshold else {
            onLandmarks?(nil)
            return
        }

        // Kumpulkan landmark
        var pts: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for joint in HandLandmarks.orderedJoints {
            if let p = try? obs.recognizedPoint(joint), p.confidence > confidenceThreshold {
                pts[joint] = p.location
            }
        }
        let landmarks = HandLandmarks(points: pts)
        onLandmarks?(landmarks)
        onWristPosition?(wristPt.location.y)

        // Smooth palmArea
        let rawArea = landmarks.palmArea
        smoothedArea = smoothedArea == 0
            ? rawArea
            : emaAlpha * rawArea + (1 - emaAlpha) * smoothedArea

        onDebug?(phase.description, smoothedArea, hasProductInFrame)

        evaluate(area: smoothedArea)
    }

    // MARK: - State Machine

    private func evaluate(area: CGFloat) {
        switch phase {

        // ─── IDLE: tunggu tangan cukup besar di frame ──────────────────
        case .idle:
            guard area >= largeAreaThreshold else { return }
            // Tangan terdeteksi cukup besar → mulai gesture, snapshot produk
            phase = .large(peakArea: area, hadProduct: hasProductInFrame)
            smallFrames = 0
            print("[HandTracker] 📍 IDLE→LARGE (area=\(String(format: "%.4f", area)), prod=\(hasProductInFrame))")

        // ─── LARGE: tangan dekat kamera, update peak sampai mulai mengecil ─
        case .large(let peakArea, let hadProduct):
            if area > peakArea {
                // Masih membesar / tetap besar — update peak
                phase = .large(peakArea: area, hadProduct: hadProduct)
                return
            }

            // Cek apakah sudah mengecil cukup
            if area < peakArea * shrinkRatio {
                // Tangan sudah masuk trolley — transisi ke fase small
                print("[HandTracker] 📍 LARGE→SMALL (peak=\(String(format: "%.4f", peakArea)), current=\(String(format: "%.4f", area)), ratio=\(String(format: "%.2f%%", area/peakArea*100)))")
                phase = .small(troughArea: area, hadProduct: hadProduct)
                smallFrames = 1
            }
            // Kalau belum cukup mengecil, tetap di large

        // ─── SMALL: tangan di dalam trolley, update trough, tunggu naik ─
        case .small(let troughArea, let hadProduct):
            smallFrames += 1

            let currentTrough = min(troughArea, area)
            phase = .small(troughArea: currentTrough, hadProduct: hadProduct)

            // Cek apakah tangan sudah naik kembali
            guard area > currentTrough * growRatio else { return }
            guard smallFrames >= minSmallFrames else {
                // Naik terlalu cepat — bukan gesture valid
                print("[HandTracker] ⚠️  False positive (too fast: \(smallFrames) < \(minSmallFrames) frames)")
                resetPhase()
                return
            }

            // Tangan sudah kembali besar — bandingkan kondisi produk
            let hasNow = hasProductInFrame

            if hadProduct && !hasNow {
                // Bawa produk masuk, kembali kosong → PUT
                print("[HandTracker] ✅ PUT gesture (had=true, now=false)")
                fire(.approachingBasket)
            } else if !hadProduct && hasNow {
                // Masuk kosong, kembali bawa produk → TAKE
                print("[HandTracker] ✅ TAKE gesture (had=false, now=true)")
                fire(.leavingBasket)
            } else {
                // Kondisi sama → bukan gesture valid
                print("[HandTracker] ⚠️  No gesture (condition same: had=\(hadProduct), now=\(hasNow))")
                resetPhase()
            }
        }
    }

    // MARK: - Helpers

    private func fire(_ action: HandAction) {
        onAction?(action)
        resetPhase()
    }

    private func resetPhase() {
        phase         = .idle
        smallFrames   = 0
        missingFrames = 0
        // NOTE: Do NOT reset smoothedArea here.
        // Keeping EMA state continuous prevents sudden jumps when hand tracking
        // temporarily fails and recovers. This improves gesture detection stability.
        // smoothedArea will decay naturally via EMA if no new frames arrive.
    }

    func reset() {
        resetPhase()
        hasProductInFrame = false
        // Only reset smoothedArea on manual reset (e.g., clearing history)
        smoothedArea = 0
    }
}
