
import SwiftUI
import AVFoundation

// MARK: - Camera Preview
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var session: AVCaptureSession? {
        didSet {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspect
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

// MARK: - Bounding Box Overlay
struct BoundingBoxOverlay: View {
    let detections: [DetectionResult]
    let viewSize: CGSize
    let onTap: (DetectionResult) -> Void

    var body: some View {
        ZStack {
            ForEach(Array(detections.enumerated()), id: \.offset) { _, detection in
                BoundingBoxView(detection: detection, viewSize: viewSize, onTap: { onTap(detection) })
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
    }
}

// MARK: - Single Bounding Box
struct BoundingBoxView: View {
    let detection: DetectionResult
    let viewSize: CGSize
    let onTap: () -> Void

    @State private var isHighlighted = false

    private var product: Product? { detection.product }

    // Convert normalized bbox → screen pixels
    // Vision gives origin at bottom-left, we need top-left
    private var boxRect: CGRect {
        let bb = detection.boundingBox  // already converted to top-left in detector
        let x = bb.minX * viewSize.width
        let y = bb.minY * viewSize.height
        let w = bb.width  * viewSize.width
        let h = bb.height * viewSize.height

        // Clamp to view bounds
        let cx = min(max(x, 0), viewSize.width)
        let cy = min(max(y, 0), viewSize.height)
        let cw = min(w, viewSize.width  - cx)
        let ch = min(h, viewSize.height - cy)
        return CGRect(x: cx, y: cy, width: cw, height: ch)
    }

    private var boxColor: Color {
        detection.confidence > 0.70 ? .green : detection.confidence > 0.50 ? .yellow : .orange
    }

    // Label badge position — keep it inside screen
    private var labelX: CGFloat {
        let preferred = boxRect.minX
        let maxX = viewSize.width - 160
        return min(max(preferred, 4), maxX)
    }
    private var labelY: CGFloat {
        let preferred = boxRect.minY - 52
        return max(preferred, 4)  // don't go above screen top
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Box outline
            Rectangle()
                .stroke(boxColor, lineWidth: isHighlighted ? 4 : 2.5)
                .background(boxColor.opacity(isHighlighted ? 0.2 : 0.06))
                .frame(width: boxRect.width, height: boxRect.height)
                .position(x: boxRect.midX, y: boxRect.midY)

            // Label badge
            if let product {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(product.emoji).font(.system(size: 13))
                        Text(product.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(product.formattedPrice)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.0f%%", detection.confidence * 100))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    Text("Tap untuk tambah")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.78))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(boxColor.opacity(0.7), lineWidth: 1))
                )
                .position(x: labelX + 75, y: labelY + 26)  // position uses center, so offset by half badge size
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only trigger if tap is inside box
            withAnimation(.easeInOut(duration: 0.1)) { isHighlighted = true }
            onTap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation { isHighlighted = false }
            }
        }
    }
}
