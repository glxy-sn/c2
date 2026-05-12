import Foundation
import CoreML
import Vision
import UIKit
import Combine

class GroceryDetector: ObservableObject {

    @Published var detections: [DetectionResult] = []
    @Published var isModelLoaded: Bool = false
    @Published var errorMessage: String?

    private var visionModel: VNCoreMLModel?
    private var request: VNCoreMLRequest?

    let confidenceThreshold: Float = 0.35
    let iouThreshold: Float = 0.45
    private let numClasses = 16
    
    // Bounding box smoothing
    private var smoothedDetections: [Int: SmoothedBBox] = [:]  // classIndex -> smoothed bbox
    private let bboxSmoothingAlpha: CGFloat = 0.4  // 40% weight on current frame

    init() { loadModel() }
    
    // MARK: - Detection Smoothing
    
    private struct SmoothedBBox {
        var bbox: CGRect
        var confidence: Float
        var lastSeen: Date
    }
    
    /// Apply EMA smoothing to detections untuk stabilize bounding boxes
    private func smoothDetections(_ detections: [DetectionResult]) -> [DetectionResult] {
        let now = Date()
        let stalenessThreshold: TimeInterval = 0.5  // 500ms
        
        // Remove stale smoothed detections (not seen for a while)
        smoothedDetections = smoothedDetections.filter { _, val in
            now.timeIntervalSince(val.lastSeen) < stalenessThreshold
        }
        
        var smoothedResults: [DetectionResult] = []
        
        for det in detections {
            let key = "\(det.classIndex)_\(det.confidence)".hashValue  // Simple key combining class and confidence
            
            if let existing = smoothedDetections[det.classIndex] {
                // Apply EMA smoothing to bounding box
                let smoothedBBox = CGRect(
                    x: bboxSmoothingAlpha * det.boundingBox.minX + (1 - bboxSmoothingAlpha) * existing.bbox.minX,
                    y: bboxSmoothingAlpha * det.boundingBox.minY + (1 - bboxSmoothingAlpha) * existing.bbox.minY,
                    width: bboxSmoothingAlpha * det.boundingBox.width + (1 - bboxSmoothingAlpha) * existing.bbox.width,
                    height: bboxSmoothingAlpha * det.boundingBox.height + (1 - bboxSmoothingAlpha) * existing.bbox.height
                )
                
                let smoothedConf = Float(bboxSmoothingAlpha) * det.confidence + Float(1 - bboxSmoothingAlpha) * existing.confidence
                
                smoothedDetections[det.classIndex] = SmoothedBBox(
                    bbox: smoothedBBox,
                    confidence: smoothedConf,
                    lastSeen: now
                )
                
                smoothedResults.append(DetectionResult(
                    classIndex: det.classIndex,
                    confidence: smoothedConf,
                    boundingBox: smoothedBBox
                ))
            } else {
                // First time seeing this class — initialize smoothing
                smoothedDetections[det.classIndex] = SmoothedBBox(
                    bbox: det.boundingBox,
                    confidence: det.confidence,
                    lastSeen: now
                )
                smoothedResults.append(det)
            }
        }
        
        return smoothedResults
    }

    // MARK: - Load Model

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
                
                // Log model input/output description for debugging
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

    // MARK: - Handle results
    private func handleDetectionResults(request: VNRequest) {
        guard let results = request.results, !results.isEmpty else {
            DispatchQueue.main.async { self.detections = [] }
            return
        }

        var newDetections: [DetectionResult] = []

        // Case 1: Vision already parsed YOLO output into objects
        if let observations = results as? [VNRecognizedObjectObservation] {
            print("📦 Got \(observations.count) VNRecognizedObjectObservation")
            for obs in observations {
                guard let top = obs.labels.first, top.confidence >= confidenceThreshold else { continue }
                let classIndex = classIndexFromLabel(top.identifier)
                let bb = obs.boundingBox  // normalized, origin bottom-left
                let converted = CGRect(x: bb.minX, y: 1.0 - bb.maxY, width: bb.width, height: bb.height)
                newDetections.append(DetectionResult(classIndex: classIndex, confidence: top.confidence, boundingBox: converted))
            }
        }
        // Case 2: Raw tensor output — parse safely
        else if let observations = results as? [VNCoreMLFeatureValueObservation] {
            print("📦 Got \(observations.count) VNCoreMLFeatureValueObservation")
            for obs in observations {
                print("  feature '\(obs.featureName)': \(obs.featureValue.type)")
            }
            newDetections = safeParseRawOutput(observations)
        }
        else {
            print("⚠️ Unknown result type: \(type(of: results.first))")
        }

        let filtered = applyNMS(detections: newDetections)
        let smoothed = smoothDetections(filtered)  // Apply EMA smoothing untuk stabilize boxes
        print("🎯 Detections after smoothing: \(smoothed.count)")
        DispatchQueue.main.async { self.detections = smoothed }
    }

    // MARK: - Safe raw tensor parser
    // YOLOv11 output shape: [1, 20, 8400] where 20 = 4 (box) + 16 (classes)
    // OR transposed: [1, 8400, 20]
    private func safeParseRawOutput(_ observations: [VNCoreMLFeatureValueObservation]) -> [DetectionResult] {
        guard let obs = observations.first,
              let multiArray = obs.featureValue.multiArrayValue else { return [] }

        let shape = multiArray.shape.map { $0.intValue }
        print("🔢 Output shape: \(shape)")

        let featCount = numClasses + 4  // 20

        // Determine layout
        // [batch, featCount, anchors] → transposed=false
        // [batch, anchors, featCount] → transposed=true
        let anchors: Int
        let transposed: Bool

        if shape.count == 3 {
            if shape[1] == featCount {
                anchors = shape[2]
                transposed = false
                print("📐 Layout: [batch=\(shape[0]), features=\(shape[1]), anchors=\(shape[2])]")
            } else if shape[2] == featCount {
                anchors = shape[1]
                transposed = true
                print("📐 Layout: [batch=\(shape[0]), anchors=\(shape[1]), features=\(shape[2])] (transposed)")
            } else {
                print("⚠️ Unexpected shape: \(shape)")
                return []
            }
        } else if shape.count == 2 {
            if shape[0] == featCount {
                anchors = shape[1]; transposed = false
            } else {
                anchors = shape[0]; transposed = true
            }
        } else {
            print("⚠️ Cannot handle shape: \(shape)")
            return []
        }

        var results: [DetectionResult] = []

        // Use safe Swift subscript instead of raw pointer
        for i in 0..<anchors {
            func val(_ f: Int) -> Float {
                let idx: Int
                if transposed {
                    idx = i * featCount + f
                } else {
                    idx = f * anchors + i
                }
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

            // Normalize to 0..1 (model input 640x640)
            let x = CGFloat((cx - w / 2) / 640)
            let y = CGFloat((cy - h / 2) / 640)
            let bw = CGFloat(w / 640)
            let bh = CGFloat(h / 640)

            guard bw > 0, bh > 0, x >= -0.5, y >= -0.5 else { continue }

            results.append(DetectionResult(
                classIndex: maxClass,
                confidence: maxConf,
                boundingBox: CGRect(x: x, y: y, width: bw, height: bh)
            ))
        }

        print("🔍 Raw detections before NMS: \(results.count)")
        return results
    }

    // MARK: - NMS
    private func applyNMS(detections: [DetectionResult]) -> [DetectionResult] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [DetectionResult] = []
        var suppressed = [Bool](repeating: false, count: sorted.count)
        for i in 0..<sorted.count {
            guard !suppressed[i] else { continue }
            kept.append(sorted[i])
            for j in (i+1)..<sorted.count {
                if iou(sorted[i].boundingBox, sorted[j].boundingBox) > CGFloat(iouThreshold) {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    private func classIndexFromLabel(_ label: String) -> Int {
        if let idx = Int(label) { return idx }
        for (idx, product) in ProductDatabase.products {
            if product.name.lowercased() == label.lowercased() { return idx }
        }
        return 0
    }
}
