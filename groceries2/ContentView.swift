import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var cameraManager  = CameraManager()
    @StateObject private var detector       = GroceryDetector()
    @StateObject private var cartManager    = CartManager()
    @StateObject private var basketManager  = BasketManager()

    @State private var showCheckout:    Bool         = false
    @State private var torchOn:         Bool         = false
    @State private var scannerActive:   Bool         = true
    @State private var activeBasketToast: BasketEvent? = nil

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {

                // MARK: - Camera area (top 58%)
                ZStack {
                    if cameraManager.permissionGranted {
                        CameraPreviewView(session: cameraManager.session)
                            .ignoresSafeArea(edges: .top)
                    } else {
                        PermissionDeniedView()
                    }

                    // Bounding box overlay — gesture-based only
                    if scannerActive && !detector.detections.isEmpty {
                        let camSize = CGSize(width: geo.size.width, height: geo.size.height * 1)
                        BoundingBoxOverlay(
                            detections: detector.detections,
                            viewSize: camSize,
                            onTap: { _ in }  // Gesture-based only, no manual tap
                        )
                    }

                    // Hand skeleton overlay
                    HandOverlayView(
                        landmarks: basketManager.landmarks,
                        size: CGSize(width: geo.size.width, height: geo.size.height * 1)
                    )

                    // Top control bar
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("🛒 GroceryScanner")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                Text(detector.isModelLoaded
                                     ? "Siap • \(detector.detections.count) objek"
                                     : "Memuat model...")
                                    .font(.system(size: 12))
                                    .foregroundColor(detector.isModelLoaded ? .green : .yellow)
                            }
                            Spacer()
                            HStack(spacing: 10) {
                                Button {
                                    torchOn.toggle()
                                    cameraManager.toggleTorch(on: torchOn)
                                } label: {
                                    Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(torchOn ? .yellow : .white)
                                        .frame(width: 36, height: 36)
                                        .background(Color.white.opacity(0.2))
                                        .clipShape(Circle())
                                }
                                Button { scannerActive.toggle() } label: {
                                    Image(systemName: scannerActive ? "pause.fill" : "play.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                        .background(Color.white.opacity(0.2))
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                        .background(
                            LinearGradient(colors: [.black.opacity(0.65), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        )

                        Spacer()

                        if detector.detections.isEmpty && scannerActive {
                            VStack(spacing: 6) {
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 36)).foregroundColor(.white.opacity(0.5))
                                Text("Arahkan kamera ke produk")
                                    .font(.system(size: 14, weight: .medium)).foregroundColor(.white.opacity(0.7))
                                Text("Pegang produk untuk masuk/keluar dari keranjang")
                                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                            }
                            .padding(16)
                            .background(Color.black.opacity(0.45))
                            .cornerRadius(14)
                            .padding(.bottom, 20)
                        }

                        if let error = detector.errorMessage {
                            Text("⚠️ \(error)")
                                .font(.system(size: 11)).foregroundColor(.red)
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8).padding(.bottom, 8)
                        }
                    }

                    // Basket event toast (PUT/TAKE)
                    if let event = activeBasketToast {
                        BasketActivityToast(event: event)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity))
                    }

                    // Hand gesture badge + debug panel
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                // Show item count + debug phase
                                HStack(spacing: 6) {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(basketManager.debugIsHolding ? .green : .gray)
                                    Text("🛒 \(basketManager.itemCount)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color.black.opacity(0.7))
                                    .overlay(Capsule().stroke(
                                        basketManager.debugIsHolding ? Color.green.opacity(0.5) : Color.gray.opacity(0.5),
                                        lineWidth: 1)))
                                
                                // Debug panel
                                HandDebugPanel(
                                    phase: basketManager.debugPhase,
                                    boxArea: basketManager.debugBoxArea,
                                    overlapRatio: basketManager.debugOverlapRatio,
                                    areaRatio: basketManager.debugAreaRatio,
                                    hasLandmarks: basketManager.landmarks != nil
                                )
                            }
                            Spacer()
                        }
                        .padding(.leading, 12).padding(.bottom, 8)
                    }
                }
                .frame(height: geo.size.height * 1)
                .overlay(alignment: .bottom) {
                    CartPanelView(
                        cartManager: cartManager,
                        onCheckout: { showCheckout = true }
                    )
                    .frame(height: geo.size.height * 0.42)
                }

                
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            // ── Wire cartManager ke basketManager ──────────────────────────
            // BasketManager sekarang manage cart langsung saat gesture fire.
            // Tidak perlu onBasketEvent untuk logic cart — hanya untuk toast UI.
            basketManager.cartManager = cartManager

            // ── Camera frame callback ──────────────────────────────────────
            let processor = basketManager.handPoseProcessor
            cameraManager.onFrame = { [weak detector, weak basketManager] pixelBuffer in
                detector?.detect(pixelBuffer: pixelBuffer)
                processor.processFrame(pixelBuffer: pixelBuffer)
            }

            // ── Toast saja — cart sudah diurus BasketManager ───────────────
            basketManager.onBasketEvent = { event in
                Task { @MainActor in
                    withAnimation(.spring(response: 0.35)) { activeBasketToast = event }
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { activeBasketToast = nil }
                }
            }

            cameraManager.startSession()
        }
        .onDisappear { cameraManager.stopSession() }

        // ── Detection + landmarks → process for depth-based gesture ─────────
        .onReceive(detector.$detections) { newDetections in
            let camSize = CGSize(width: UIScreen.main.bounds.width,
                               height: UIScreen.main.bounds.height * 1)
            basketManager.processFrame(detections: newDetections, viewSize: camSize)
        }

        .sheet(isPresented: $showCheckout) {
            CheckoutView(cartManager: cartManager)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Basket Activity Toast

struct BasketActivityToast: View {
    let event: BasketEvent

    private var isPut: Bool { event.action == .put }
    private var accent: Color { isPut ? .green : .orange }
    private var emoji: String {
        ProductDatabase.products.values.first(where: { $0.name == event.itemName })?.emoji
            ?? (isPut ? "📥" : "📤")
    }

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(accent.opacity(0.2)).frame(width: 40, height: 40)
                    Image(systemName: isPut ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22)).foregroundColor(accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPut ? "Barang Dimasukkan" : "Barang Diambil")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(accent)
                    HStack(spacing: 4) {
                        Text(emoji).font(.system(size: 14))
                        Text(event.itemName)
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    }
                    if event.confidence > 0 {
                        Text(String(format: "Confidence: %.0f%%", event.confidence * 100))
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                    }
                }
                Spacer()
                Text(event.timeString)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.85))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.6), lineWidth: 1.5))
            )
            .padding(.horizontal, 12).padding(.top, 70)
            Spacer()
        }
    }
}

// MARK: - Hand Debug Panel

struct HandDebugPanel: View {
    let phase: String
    let boxArea: CGFloat
    let overlapRatio: CGFloat
    let areaRatio: CGFloat
    let hasLandmarks: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(hasLandmarks ? Color.green : Color.red).frame(width: 6, height: 6)
                Text(hasLandmarks ? "Hand ✓" : "No hand")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(hasLandmarks ? .green : .red)
            }
            Text("Phase: \(phase)").font(.system(size: 9, design: .monospaced)).foregroundColor(.cyan)
            Text(String(format: "Box: %.4f", boxArea))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.7))
            Text(String(format: "Overlap: %.0f%%", overlapRatio * 100))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.yellow.opacity(0.8))
            Text(String(format: "Ratio: %.1f%%", areaRatio * 100))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)))
    }
}

// MARK: - Permission denied

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 50)).foregroundColor(.gray)
            Text("Izin Kamera Diperlukan").font(.title2.bold()).foregroundColor(.white)
            Text("Buka Settings > Privacy > Camera > aktifkan GroceryScanner")
                .font(.body).foregroundColor(.gray).multilineTextAlignment(.center)
            Button("Buka Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }.buttonStyle(.bordered)
        }.padding(40)
    }
}

import UIKit

