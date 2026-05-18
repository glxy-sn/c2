import Foundation
import CoreML
import Vision
import UIKit
import Combine

// MARK: - Tracked Detection (internal)
private struct TrackedDetection {
    let id: UUID
    var classIndex: Int
    var smoothedConfidence: Float
    var smoothedBox: CGRect
    var missedFrames: Int = 0
    var confirmedFrames: Int = 0
}

class GroceryDetector: ObservableObject {

    @Published var detections: [DetectionResult] = []
    @Published var isModelLoaded: Bool = false
    @Published var errorMessage: String?

    private var visionModel: VNCoreMLModel?
    private var request: VNCoreMLRequest?

    let confidenceThreshold: Float = 0.55
    let iouThreshold: Float = 0.30
    private let numClasses = 12

    // MARK: - Temporal Smoothing Config
    // FIX: Lebih lambat & toleran saat kamera goyang
    private let emaAlpha: Float = 0.20            // lebih kecil = lebih smooth (was 0.30)
    private let maxMissedFrames: Int = 18         // lebih toleran sebelum hapus (was 10)
    private let minFramesToShow: Int = 3          // butuh konfirmasi 3 frame sebelum tampil (was 1)
    private let matchIoUThreshold: CGFloat = 0.10 // minimum IoU untuk match (dipakai bersama distance)
    private let maxCenterDistance: CGFloat = 0.20 // FIX: fallback matching by center distance (normalized)

    private var trackedDetections: [UUID: TrackedDetection] = [:]

    init() { loadModel() }

    // MARK: - Load Model
    private func loadModel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let modelURL: URL
                if let url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc") {
                    print("✅ Found best.mlmodelc")
                    modelURL = url
                } else if let url = Bundle.main.url(forResource: "best", withExtension: "mlpackage") {
                    print("✅ Found best.mlpackage")
                    modelURL = url
                } else {
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.bundlePath)) ?? []
                    print("❌ Model not found. Bundle contents: \(contents)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Model tidak ditemukan. Files: \(contents.filter { $0.contains("ml") || $0.contains("best") })"
                    }
                    return
                }

                let config = MLModelConfiguration()
                config.computeUnits = .all

                let mlModel = try MLModel(contentsOf: modelURL, configuration: config)

                let desc = mlModel.modelDescription
                print("📐 Model inputs: \(desc.inputDescriptionsByName.keys)")
                print("📐 Model outputs: \(desc.outputDescriptionsByName.keys)")
                for (name, out) in desc.outputDescriptionsByName {
                    print("  output '\(name)': \(out.type) \(out.multiArrayConstraint?.shape ?? [])")
                }

                let vnModel = try VNCoreMLModel(for: mlModel)
                let req = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
                    if let error { print("Vision error: \(error)"); return }
                    self?.handleDetectionResults(request: request)
                }
                req.imageCropAndScaleOption = .scaleFill

                DispatchQueue.main.async {
                    self.visionModel = vnModel
                    self.request = req
                    self.isModelLoaded = true
                    print("✅ Model loaded successfully")
                }
            } catch {
                print("❌ Load error: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = "Gagal load model: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Detect
    func detect(pixelBuffer: CVPixelBuffer) {
        guard let request else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        DispatchQueue.global(qos: .userInteractive).async {
            do { try handler.perform([request]) }
            catch { print("Perform error: \(error)") }
        }
    }

    // MARK: - Handle Results
    private func handleDetectionResults(request: VNRequest) {
        guard let results = request.results, !results.isEmpty else {
            let smoothed = updateTracker(with: [])
            DispatchQueue.main.async { self.detections = smoothed }
            return
        }

        var newDetections: [DetectionResult] = []

        if let observations = results as? [VNRecognizedObjectObservation] {
            print("📦 Got \(observations.count) VNRecognizedObjectObservation")
            for obs in observations {
                guard let top = obs.labels.first, top.confidence >= confidenceThreshold else { continue }
                let classIndex = classIndexFromLabel(top.identifier)
                let bb = obs.boundingBox
                let converted = CGRect(x: bb.minX, y: 1.0 - bb.maxY, width: bb.width, height: bb.height)
                newDetections.append(DetectionResult(classIndex: classIndex, confidence: top.confidence, boundingBox: converted))
            }
        } else if let observations = results as? [VNCoreMLFeatureValueObservation] {
            print("📦 Got \(observations.count) VNCoreMLFeatureValueObservation")
            newDetections = safeParseRawOutput(observations)
        } else {
            print("⚠️ Unknown result type: \(type(of: results.first))")
        }

        let afterNMS = applyNMS(detections: newDetections)
        print("🎯 Detections after NMS: \(afterNMS.count)")

        let smoothed = updateTracker(with: afterNMS)
        DispatchQueue.main.async { self.detections = smoothed }
    }

    // MARK: - IoU-based Instance Tracker (with distance fallback)
    private func updateTracker(with newDetections: [DetectionResult]) -> [DetectionResult] {
        var matchedIDs = Set<UUID>()
        var unmatchedDetections: [DetectionResult] = []

        for det in newDetections {
            // FIX: Scoring gabungan IoU + center distance, tidak hanya IoU
            var bestID: UUID? = nil
            var bestScore: CGFloat = -1

            for (id, tracked) in trackedDetections {
                guard tracked.classIndex == det.classIndex else { continue }
                guard !matchedIDs.contains(id) else { continue }

                let overlapIoU = iou(tracked.smoothedBox, det.boundingBox)
                let dist = centerDistance(tracked.smoothedBox, det.boundingBox)

                // Match valid jika: IoU cukup ATAU (IoU rendah tapi center dekat)
                // Ini yang bikin tahan goyang — saat goyang, IoU turun tapi center masih dekat
                let distScore = max(0, 1.0 - dist / maxCenterDistance)
                let combinedScore = overlapIoU * 0.5 + distScore * 0.5

                let isValidMatch = overlapIoU >= matchIoUThreshold || dist < maxCenterDistance

                if isValidMatch && combinedScore > bestScore {
                    bestScore = combinedScore
                    bestID = id
                }
            }

            if let id = bestID {
                matchedIDs.insert(id)
                var tracked = trackedDetections[id]!

                tracked.smoothedConfidence = emaAlpha * det.confidence + (1 - emaAlpha) * tracked.smoothedConfidence

                let nb = det.boundingBox
                let ob = tracked.smoothedBox
                tracked.smoothedBox = CGRect(
                    x:      CGFloat(emaAlpha) * nb.minX   + CGFloat(1 - emaAlpha) * ob.minX,
                    y:      CGFloat(emaAlpha) * nb.minY   + CGFloat(1 - emaAlpha) * ob.minY,
                    width:  CGFloat(emaAlpha) * nb.width  + CGFloat(1 - emaAlpha) * ob.width,
                    height: CGFloat(emaAlpha) * nb.height + CGFloat(1 - emaAlpha) * ob.height
                )
                tracked.missedFrames = 0
                tracked.confirmedFrames += 1
                trackedDetections[id] = tracked
            } else {
                unmatchedDetections.append(det)
            }
        }

        // Naikkan missedFrames untuk yang tidak ke-match
        for id in trackedDetections.keys where !matchedIDs.contains(id) {
            trackedDetections[id]?.missedFrames += 1
        }

        // Hapus yang sudah terlalu lama hilang
        trackedDetections = trackedDetections.filter { $0.value.missedFrames <= maxMissedFrames }

        // FIX: Cegah objek baru jika sudah ada tracked object dengan class sama yang dekat
        // Ini mencegah duplikat saat goyang ekstrem (IoU = 0 tapi sebenarnya objek sama)
        let filteredUnmatched = unmatchedDetections.filter { det in
            !trackedDetections.values.contains { tracked in
                tracked.classIndex == det.classIndex &&
                centerDistance(tracked.smoothedBox, det.boundingBox) < maxCenterDistance * 1.5
            }
        }

        // Tambahkan objek baru yang benar-benar baru
        for det in filteredUnmatched {
            let newID = UUID()
            trackedDetections[newID] = TrackedDetection(
                id: newID,
                classIndex: det.classIndex,
                smoothedConfidence: det.confidence * 0.6,  // mulai lebih rendah, butuh konfirmasi
                smoothedBox: det.boundingBox,
                missedFrames: 0,
                confirmedFrames: 1
            )
        }

        return trackedDetections.values
            .filter { $0.confirmedFrames >= minFramesToShow && $0.smoothedConfidence >= confidenceThreshold }
            .map { tracked in
                DetectionResult(
                    classIndex: tracked.classIndex,
                    confidence: tracked.smoothedConfidence,
                    boundingBox: tracked.smoothedBox
                )
            }
    }

    // MARK: - Safe Raw Tensor Parser
    private func safeParseRawOutput(_ observations: [VNCoreMLFeatureValueObservation]) -> [DetectionResult] {
        guard let obs = observations.first,
              let multiArray = obs.featureValue.multiArrayValue else { return [] }

        let shape = multiArray.shape.map { $0.intValue }
        print("🔢 Output shape: \(shape)")

        let featCount = numClasses + 4

        let anchors: Int
        let transposed: Bool

        if shape.count == 3 {
            if shape[1] == featCount {
                anchors = shape[2]; transposed = false
                print("📐 Layout: [batch=\(shape[0]), features=\(shape[1]), anchors=\(shape[2])]")
            } else if shape[2] == featCount {
                anchors = shape[1]; transposed = true
                print("📐 Layout: [batch=\(shape[0]), anchors=\(shape[1]), features=\(shape[2])] (transposed)")
            } else {
                print("⚠️ Unexpected shape: \(shape)"); return []
            }
        } else if shape.count == 2 {
            if shape[0] == featCount { anchors = shape[1]; transposed = false }
            else { anchors = shape[0]; transposed = true }
        } else {
            print("⚠️ Cannot handle shape: \(shape)"); return []
        }

        var results: [DetectionResult] = []

        for i in 0..<anchors {
            func val(_ f: Int) -> Float {
                let idx = transposed ? i * featCount + f : f * anchors + i
                return multiArray[idx].floatValue
            }

            let cx = val(0), cy = val(1), w = val(2), h = val(3)

            var maxConf: Float = 0
            var maxClass = 0
            for c in 0..<numClasses {
                let conf = val(4 + c)
                if conf > maxConf { maxConf = conf; maxClass = c }
            }

            guard maxConf >= confidenceThreshold else { continue }

            let x  = CGFloat((cx - w / 2) / 640)
            let y  = CGFloat((cy - h / 2) / 640)
            let bw = CGFloat(w / 640)
            let bh = CGFloat(h / 640)

            guard bw > 0.02, bh > 0.02, bw < 0.95, bh < 0.95 else { continue }
            guard x >= -0.1, y >= -0.1 else { continue }

            results.append(DetectionResult(
                classIndex: maxClass,
                confidence: maxConf,
                boundingBox: CGRect(x: x, y: y, width: bw, height: bh)
            ))
        }

        print("🔍 Raw detections before NMS: \(results.count)")
        return results
    }

    // MARK: - NMS Per Class
    private func applyNMS(detections: [DetectionResult]) -> [DetectionResult] {
        let grouped = Dictionary(grouping: detections) { $0.classIndex }
        var result: [DetectionResult] = []

        for (_, classDetections) in grouped {
            let sorted = classDetections.sorted { $0.confidence > $1.confidence }
            var suppressed = [Bool](repeating: false, count: sorted.count)

            for i in 0..<sorted.count {
                guard !suppressed[i] else { continue }
                result.append(sorted[i])
                for j in (i+1)..<sorted.count {
                    if iou(sorted[i].boundingBox, sorted[j].boundingBox) > CGFloat(iouThreshold) {
                        suppressed[j] = true
                    }
                }
            }
        }
        return result
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // FIX: Helper baru — jarak antar center (normalized 0..1)
    private func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func classIndexFromLabel(_ label: String) -> Int {
        if let idx = Int(label) { return idx }
        for (idx, product) in ProductDatabase.products {
            if product.name.lowercased() == label.lowercased() { return idx }
        }
        return 0
    }
}
