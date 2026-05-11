import Foundation
import CoreML
import Vision
import UIKit
import Combine

// MARK: - YOLOv11 Detector
class GroceryDetector: ObservableObject {
    
    // MARK: - Published State
    @Published var detections: [DetectionResult] = []
    @Published var isModelLoaded: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Private
    private var model: MLModel?
    private var visionModel: VNCoreMLModel?
    private var request: VNCoreMLRequest?
    
    // Detection settings
    let confidenceThreshold: Float = 0.45
    let iouThreshold: Float = 0.45
    
    // MARK: - Init
    init() {
        loadModel()
    }
    
    // MARK: - Load Model
    private func loadModel() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                // Xcode compiles .mlpackage -> .mlmodelc at build time.
                // Try mlmodelc first, then mlpackage as fallback.
                let modelURL: URL
                if let url = Bundle.main.url(forResource: "best", withExtension: "mlmodelc") {
                    print("✅ Found best.mlmodelc")
                    modelURL = url
                } else if let url = Bundle.main.url(forResource: "best", withExtension: "mlpackage") {
                    print("✅ Found best.mlpackage")
                    modelURL = url
                } else {
                    // Debug: list bundle contents
                    let bundlePath = Bundle.main.bundlePath
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: bundlePath)) ?? []
                    let mlFiles = contents.filter { $0.contains("ml") || $0.contains("best") }
                    print("❌ Model not found")
                    print("📦 Bundle: \(bundlePath)")
                    print("📦 ML files: \(mlFiles)")
                    print("📦 All files: \(contents)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Model tidak ditemukan. Cek Xcode console untuk debug. ML files: \(mlFiles)"
                    }
                    return
                }
                
                let config = MLModelConfiguration()
                config.computeUnits = .all  // GPU + ANE
                
                let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
                let vnModel = try VNCoreMLModel(for: mlModel)
                
                // Create Vision request
                let req = VNCoreMLRequest(model: vnModel) { [weak self] request, error in
                    self?.handleDetectionResults(request: request, error: error)
                }
                req.imageCropAndScaleOption = .scaleFill
                
                DispatchQueue.main.async {
                    self.model = mlModel
                    self.visionModel = vnModel
                    self.request = req
                    self.isModelLoaded = true
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Gagal load model: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Run Detection
    func detect(pixelBuffer: CVPixelBuffer) {
        guard let request = request else { return }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                try handler.perform([request])
            } catch {
                print("Detection error: \(error)")
            }
        }
    }
    
    // MARK: - Handle Results
    private func handleDetectionResults(request: VNRequest, error: Error?) {
        guard let results = request.results else { return }
        
        var newDetections: [DetectionResult] = []
        
        // Handle VNRecognizedObjectObservation (standard YOLO output via Vision)
        if let observations = results as? [VNRecognizedObjectObservation] {
            for obs in observations {
                guard obs.confidence >= confidenceThreshold else { continue }
                guard let topLabel = obs.labels.first else { continue }
                
                let classIndex = classIndexFromLabel(topLabel.identifier)
                let confidence = topLabel.confidence
                
                guard confidence >= confidenceThreshold else { continue }
                
                // Vision bbox: normalized, origin bottom-left → convert to top-left
                let bbox = obs.boundingBox
                let converted = CGRect(
                    x: bbox.minX,
                    y: 1.0 - bbox.maxY,
                    width: bbox.width,
                    height: bbox.height
                )
                
                newDetections.append(DetectionResult(
                    classIndex: classIndex,
                    confidence: confidence,
                    boundingBox: converted
                ))
            }
        }
        // Handle raw MLMultiArray output
        else if let featureValueObs = results as? [VNCoreMLFeatureValueObservation] {
            newDetections = parseRawOutput(featureValueObs)
        }
        
        let filtered = applyNMS(detections: newDetections, iouThreshold: iouThreshold)
        
        DispatchQueue.main.async { [weak self] in
            self?.detections = filtered
        }
    }
    
    // MARK: - Parse raw YOLOv11 tensor output
    private func parseRawOutput(_ observations: [VNCoreMLFeatureValueObservation]) -> [DetectionResult] {
        var results: [DetectionResult] = []
        
        guard let first = observations.first,
              let multiArray = first.featureValue.multiArrayValue else {
            return results
        }
        
        let shape = multiArray.shape.map { $0.intValue }
        guard shape.count >= 2 else { return results }
        
        let numClasses = 16
        let numAnchors: Int
        let numFeatures: Int
        
        if shape.last == numClasses + 4 {
            numAnchors = shape[shape.count - 2]
            numFeatures = numClasses + 4
        } else if shape[shape.count - 2] == numClasses + 4 {
            numAnchors = shape.last ?? 8400
            numFeatures = numClasses + 4
        } else {
            numAnchors = 8400
            numFeatures = numClasses + 4
        }
        
        let ptr = UnsafeMutablePointer<Double>(OpaquePointer(multiArray.dataPointer))
        
        for i in 0..<numAnchors {
            let cx = ptr[i * numFeatures + 0]
            let cy = ptr[i * numFeatures + 1]
            let w  = ptr[i * numFeatures + 2]
            let h  = ptr[i * numFeatures + 3]
            
            var maxConf: Double = 0
            var maxClass = 0
            for c in 0..<numClasses {
                let conf = ptr[i * numFeatures + 4 + c]
                if conf > maxConf {
                    maxConf = conf
                    maxClass = c
                }
            }
            
            let confidence = Float(maxConf)
            guard confidence >= confidenceThreshold else { continue }
            
            let x = CGFloat((cx - w/2) / 640)
            let y = CGFloat((cy - h/2) / 640)
            let bw = CGFloat(w / 640)
            let bh = CGFloat(h / 640)
            
            let bbox = CGRect(x: x, y: y, width: bw, height: bh)
            results.append(DetectionResult(classIndex: maxClass, confidence: confidence, boundingBox: bbox))
        }
        
        return results
    }
    
    // MARK: - NMS
    private func applyNMS(detections: [DetectionResult], iouThreshold: Float) -> [DetectionResult] {
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
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
    
    // MARK: - Helper: label string -> class index
    private func classIndexFromLabel(_ label: String) -> Int {
        if let idx = Int(label) { return idx }
        for (idx, product) in ProductDatabase.products {
            if product.name.lowercased() == label.lowercased() { return idx }
        }
        return 0
    }
}
