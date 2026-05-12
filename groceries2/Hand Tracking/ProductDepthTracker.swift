import Foundation
import Vision

// MARK: - Product Depth Tracker
//
// Mendeteksi gesture PUT/TAKE berdasarkan gerakan depth produk (Z-axis).
// Logika:
//   1. Tangan overlap dengan produk (>= 10%)
//   2. Monitor ukuran bounding box produk (sebagai proxy depth)
//   3. Jika box mengecil 10% → produk keluar (PUT)
//   4. Jika box membesar 10% → produk masuk (TAKE)

final class ProductDepthTracker {

    // MARK: - Config
    
    /// Minimal overlap ratio antara hand dan product untuk dianggap "holding"
    /// 10% = minimal 10% dari area produk harus overlap dengan hand
    var minOverlapRatio: CGFloat = 0.10
    
    /// Perubahan depth threshold untuk mendeteksi PUT/TAKE
    /// 10% = bounding box harus berubah ukuran 10% untuk trigger event
    var depthChangeThreshold: CGFloat = 0.10
    
    /// Minimum frames di state "holding" sebelum depth change dianggap valid
    /// Prevent false positives dari noise detection
    var minHoldingFrames: Int = 3
    
    /// Max frames tanpa overlap sebelum reset state
    /// At 30fps, 30 frames ≈ 1 detik
    var maxNoOverlapFrames: Int = 30

    // MARK: - Callbacks
    
    var onAction: ((HandAction) -> Void)?
    var onDebug: ((String, CGFloat, CGFloat, CGFloat, Bool) -> Void)?
    
    // MARK: - Private state
    
    private enum State {
        case idle
        // Sedang memegang produk, tracking depth
        case holding(
            peakArea: CGFloat,
            currentLabel: String,
            holdingFrames: Int
        )
    }
    
    private var state: State = .idle
    private var noOverlapFrames: Int = 0
    
    // EMA smoothing untuk bounding box area
    private var smoothedBoxArea: CGFloat = 0
    private let emaAlpha: CGFloat = 0.3
    
    // MARK: - Process
    
    func process(
        landmarks: HandLandmarks?,
        detections: [DetectionResult],
        viewSize: CGSize
    ) {
        guard let landmarks = landmarks else {
            resetState()
            onDebug?("no_hand", 0, 0, 0, false)
            return
        }
        
        // Compute hand bounding box
        guard let handBBox = computeHandBBox(from: landmarks) else {
            resetState()
            onDebug?("no_hand", 0, 0, 0, false)
            return
        }
        
        // Expand hand bbox slightly untuk lebih mudah trigger
        let expandedHand = handBBox.insetBy(dx: -0.08, dy: -0.08)
        
        // Cari produk dengan overlap terbesar
        var bestMatch: (detection: DetectionResult, label: String, overlapRatio: CGFloat)?
        
        for det in detections {
            guard let product = det.product else { continue }
            let ratio = overlapRatio(expandedHand, det.boundingBox)
            
            if ratio >= minOverlapRatio {
                if bestMatch == nil || ratio > bestMatch!.overlapRatio {
                    bestMatch = (det, product.name, ratio)
                }
            }
        }
        
        // Update state berdasarkan overlap
        evaluate(
            bestMatch: bestMatch,
            landmarks: landmarks,
            viewSize: viewSize
        )
    }
    
    // MARK: - State Machine
    
    private func evaluate(
        bestMatch: (detection: DetectionResult, label: String, overlapRatio: CGFloat)?,
        landmarks: HandLandmarks,
        viewSize: CGSize
    ) {
        switch state {
        
        // ─── IDLE: tunggu hand overlap dengan produk ──────────────────
        case .idle:
            guard let match = bestMatch else {
                noOverlapFrames += 1
                onDebug?("idle", 0, 0, 0, false)
                return
            }
            
            noOverlapFrames = 0
            let boxArea = match.detection.boundingBox.width * match.detection.boundingBox.height
            
            state = .holding(
                peakArea: boxArea,
                currentLabel: match.label,
                holdingFrames: 1
            )
            smoothedBoxArea = boxArea
            
            print("[ProductDepth] 📍 IDLE→HOLDING (\(match.label), area=\(String(format: "%.4f", boxArea)))")
            onDebug?("holding_start", boxArea, match.overlapRatio, 0, true)
        
        // ─── HOLDING: track depth changes ─────────────────────────────
        case .holding(let peakArea, let label, let holdingFrames):
            guard let match = bestMatch else {
                // Hilang overlap → reset
                noOverlapFrames += 1
                if noOverlapFrames > maxNoOverlapFrames {
                    resetState()
                    print("[ProductDepth] 🔄 No overlap, resetting")
                }
                return
            }
            
            noOverlapFrames = 0
            let boxArea = match.detection.boundingBox.width * match.detection.boundingBox.height
            
            // Smooth the box area
            smoothedBoxArea = smoothedBoxArea == 0
                ? boxArea
                : emaAlpha * boxArea + (1 - emaAlpha) * smoothedBoxArea
            
            let newHoldingFrames = holdingFrames + 1
            let peakAreaRatio = smoothedBoxArea / peakArea
            
            let debugPhase = String(format: "holding(%.0f%%)", peakAreaRatio * 100)
            onDebug?(debugPhase, smoothedBoxArea, match.overlapRatio, peakAreaRatio, true)
            
            // Cek apakah ada significant depth change
            if newHoldingFrames >= minHoldingFrames {
                if smoothedBoxArea < peakArea * (1 - depthChangeThreshold) {
                    // Box mengecil 10% → PUT (produk masuk trolley)
                    print("[ProductDepth] ✅ PUT gesture (\(label), area_change=\(String(format: "%.1f%%", (1 - peakAreaRatio) * 100)))")
                    fire(.approachingBasket)
                    return
                } else if smoothedBoxArea > peakArea * (1 + depthChangeThreshold) {
                    // Box membesar 10% → TAKE (produk keluar trolley)
                    print("[ProductDepth] ✅ TAKE gesture (\(label), area_change=\(String(format: "+%.1f%%", (peakAreaRatio - 1) * 100)))")
                    fire(.leavingBasket)
                    return
                }
            }
            
            // Update state dengan frame baru
            state = .holding(
                peakArea: max(peakArea, smoothedBoxArea),
                currentLabel: label,
                holdingFrames: newHoldingFrames
            )
        }
    }
    
    // MARK: - Helpers
    
    private func computeHandBBox(from lm: HandLandmarks) -> CGRect? {
        let pts = Array(lm.points.values)
        guard pts.count >= 3 else { return nil }
        
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        
        return CGRect(x: minX, y: 1.0 - maxY, width: maxX - minX, height: maxY - minY)
    }
    
    private func overlapRatio(_ hand: CGRect, _ product: CGRect) -> CGFloat {
        let inter = hand.intersection(product)
        guard !inter.isNull else { return 0 }
        let productArea = product.width * product.height
        return productArea > 0 ? (inter.width * inter.height) / productArea : 0
    }
    
    private func fire(_ action: HandAction) {
        onAction?(action)
        resetState()
    }
    
    private func resetState() {
        state = .idle
        noOverlapFrames = 0
        smoothedBoxArea = 0
    }
    
    func reset() {
        resetState()
    }
}

// MARK: - Helper extension

extension HandLandmarks {
    /// Get wrist position (top-left origin, normalized to 0..1)
    var wristPosition: CGPoint? {
        guard let wrist = points[.wrist] else { return nil }
        return CGPoint(x: wrist.x, y: 1.0 - wrist.y)
    }
}
