import Foundation
import UIKit
import Combine
import Vision

// MARK: - Basket Event

struct BasketEvent: Identifiable, Codable {
    let id: UUID
    let action: EventAction
    let itemName: String
    let confidence: Float
    let timestamp: Date

    enum EventAction: String, Codable, CaseIterable {
        case put  = "Dimasukkan"
        case take = "Diambil"
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }

    var icon: String {
        action == .put ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
    }
}

// MARK: - Hand Pose Processor

final class HandPoseProcessor {
    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let onLandmarks: (HandLandmarks?) -> Void

    init(onLandmarks: @escaping (HandLandmarks?) -> Void) {
        self.onLandmarks = onLandmarks
        self.handPoseRequest = VNDetectHumanHandPoseRequest()
        self.handPoseRequest.maximumHandCount = 1
    }

    func processFrame(pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            let observations = handPoseRequest.results ?? []
            
            guard let obs = observations.first else {
                onLandmarks(nil)
                return
            }
            
            // Kumpulkan landmarks
            var pts: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for joint in HandLandmarks.orderedJoints {
                if let p = try? obs.recognizedPoint(joint), p.confidence > 0.1 {
                    pts[joint] = p.location
                }
            }
            
            let landmarks = HandLandmarks(points: pts)
            onLandmarks(landmarks)
        } catch {
            print("[HandPose] Error: \(error)")
            onLandmarks(nil)
        }
    }
}

// MARK: - BasketManager
//
// Baru: Menggunakan ProductDepthTracker untuk deteksi gesture PUT/TAKE
// berdasarkan overlap hand+produk dan perubahan depth (bounding box size).
// Langsung update CartManager saat gesture fire.

@MainActor
final class BasketManager: ObservableObject {

    @Published var history:       [BasketEvent] = []
    @Published var itemCount:     Int           = 0
    @Published var wristY:        CGFloat       = 0
    @Published var lastEvent:     BasketEvent?  = nil
    @Published var landmarks:     HandLandmarks? = nil

    // Debug
    @Published var debugPhase:        String  = "idle"
    @Published var debugBoxArea:      CGFloat = 0
    @Published var debugOverlapRatio: CGFloat = 0
    @Published var debugAreaRatio:    CGFloat = 0
    @Published var debugIsHolding:    Bool    = false

    let depthTracker = ProductDepthTracker()
    lazy var handPoseProcessor = HandPoseProcessor { [weak self] landmarks in
        Task { @MainActor in self?.landmarks = landmarks }
    }

    // CartManager reference — diset dari ContentView
    weak var cartManager: CartManager?

    // Toast callback untuk ContentView (UI only)
    var onBasketEvent: ((BasketEvent) -> Void)?

    // Cooldown untuk prevent spam
    private var lastEventTime: Date = .distantPast
    private let minEventInterval: TimeInterval = 1.5
    
    // Store current detections untuk diakses saat gesture fire
    private var currentDetections: [DetectionResult] = []

    // MARK: - Init

    init() {
        bindDepthTracker()
    }

    private func bindDepthTracker() {
        depthTracker.onAction = { [weak self] action in
            Task { @MainActor in self?.handleDepthAction(action) }
        }
        depthTracker.onDebug = { [weak self] phase, boxArea, overlap, areaRatio, isHolding in
            Task { @MainActor in
                guard let self else { return }
                self.debugPhase        = phase
                self.debugBoxArea      = boxArea
                self.debugOverlapRatio = overlap
                self.debugAreaRatio    = areaRatio
                self.debugIsHolding    = isHolding
            }
        }
    }

    // MARK: - Process detections and landmarks
    //
    // Dipanggil dari ContentView setiap frame dengan latest hand landmarks
    // dan product detections. ProductDepthTracker akan:
    //   1. Check overlap hand + produk
    //   2. Track depth changes
    //   3. Fire gesture saat depth threshold tercapai

    func processFrame(
        detections: [DetectionResult],
        viewSize: CGSize
    ) {
        currentDetections = detections
        depthTracker.process(
            landmarks: landmarks,
            detections: detections,
            viewSize: viewSize
        )
    }

    // MARK: - Handle Depth Action
    //
    // Dipanggil oleh ProductDepthTracker saat gesture fire.
    // Langsung update CartManager dan create event untuk toast.

    private func handleDepthAction(_ action: HandAction) {
        guard action != .idle else { return }

        let now = Date()
        guard now.timeIntervalSince(lastEventTime) >= minEventInterval else {
            print("[Basket] ⏱ Cooldown aktif, event diabaikan")
            return
        }
        lastEventTime = now

        switch action {

        // ── PUT: tangan + produk bergerak jauh dari kamera (box mengecil) ──
        case .approachingBasket:
            // Cari produk yang sedang dipegang dari detections terbaru
            if let product = findBestProductInHand() {
                cartManager?.addProduct(product)
                print("[Basket] ✅ PUT — \(product.name)")
                
                let event = BasketEvent(
                    id: UUID(),
                    action: .put,
                    itemName: product.name,
                    confidence: 0.80,
                    timestamp: now
                )
                history.insert(event, at: 0)
                lastEvent = event
                itemCount += 1
                
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onBasketEvent?(event)
            } else {
                print("[Basket] ⚠️ PUT fired tapi tidak bisa identify produk")
            }

        // ── TAKE: tangan + produk bergerak mendekat ke kamera (box membesar) ──
        case .leavingBasket:
            // Coba ambil produk terakhir yang ditambahkan ke cart
            if let removed = cartManager?.removeLastAdded() {
                print("[Basket] ✅ TAKE — \(removed)")
                
                let event = BasketEvent(
                    id: UUID(),
                    action: .take,
                    itemName: removed,
                    confidence: 0.50,
                    timestamp: now
                )
                history.insert(event, at: 0)
                lastEvent = event
                itemCount = max(0, itemCount - 1)
                
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onBasketEvent?(event)
            } else {
                print("[Basket] ⚠️ TAKE: tidak ada produk di cart untuk diambil")
            }

        case .idle:
            return
        }
    }

    // MARK: - Helpers

    /// Cari produk dengan overlap terbesar terhadap hand saat ini
    private func findBestProductInHand() -> Product? {
        guard let lm = landmarks, let handRect = computeHandBBox(from: lm) else {
            return nil
        }
        
        let expandedHand = handRect.insetBy(dx: -0.08, dy: -0.08)
        
        var bestProduct: (product: Product, ratio: CGFloat)?
        for det in currentDetections {
            guard let product = det.product else { continue }
            let ratio = overlapRatio(expandedHand, det.boundingBox)
            
            if ratio >= 0.10 {
                if bestProduct == nil || ratio > bestProduct!.ratio {
                    bestProduct = (product, ratio)
                }
            }
        }
        
        return bestProduct?.product
    }

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

    // MARK: - Clear

    func clearHistory() {
        history.removeAll()
        itemCount = 0
        lastEvent = nil
        depthTracker.reset()
    }
}
