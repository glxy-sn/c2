import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var detector = GroceryDetector()
    @StateObject private var cartManager = CartManager()
    
    @State private var showCheckout: Bool = false
    @State private var recentlyAdded: Product? = nil
    @State private var previewSize: CGSize = .zero
    @State private var torchOn: Bool = false
    @State private var scannerActive: Bool = true
    
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
                    
                    // Bounding box overlay
                    if scannerActive && !detector.detections.isEmpty {
                        let camSize = CGSize(width: geo.size.width, height: geo.size.height * 0.58)
                        BoundingBoxOverlay(
                            detections: detector.detections,
                            viewSize: camSize,
                            onTap: { detection in
                                if let product = detection.product {
                                    addToCart(product)
                                }
                            }
                        )
                    }
                    
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
                                Button(action: {
                                    torchOn.toggle()
                                    cameraManager.toggleTorch(on: torchOn)
                                }) {
                                    Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(torchOn ? .yellow : .white)
                                        .frame(width: 36, height: 36)
                                        .background(Color.white.opacity(0.2))
                                        .clipShape(Circle())
                                }
                                Button(action: { scannerActive.toggle() }) {
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
                        
                        // Empty state hint
                        if detector.detections.isEmpty && scannerActive {
                            VStack(spacing: 6) {
                                Image(systemName: "viewfinder")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white.opacity(0.5))
                                Text("Arahkan kamera ke produk")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.7))
                                Text("Tap kotak untuk tambah ke keranjang")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .padding(16)
                            .background(Color.black.opacity(0.45))
                            .cornerRadius(14)
                            .padding(.bottom, 20)
                        }
                        
                        if let error = detector.errorMessage {
                            Text("⚠️ \(error)")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                                .padding(.bottom, 8)
                        }
                    }
                    
                    // Toast
                    if let added = recentlyAdded {
                        AddedProductToast(product: added)
                            .transition(.asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .frame(height: geo.size.height * 0.58)
                
                // MARK: - Cart panel (bottom 42%)
                CartPanelView(
                    cartManager: cartManager,
                    onCheckout: { showCheckout = true }
                )
                .frame(height: geo.size.height * 0.42)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            cameraManager.startSession()
            cameraManager.onFrame = { [weak detector] pixelBuffer in
                detector?.detect(pixelBuffer: pixelBuffer)
            }
        }
        .onDisappear { cameraManager.stopSession() }
        .sheet(isPresented: $showCheckout) {
            CheckoutView(cartManager: cartManager)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }
    
    private func addToCart(_ product: Product) {
        cartManager.addProduct(product)
        withAnimation(.spring(response: 0.3)) { recentlyAdded = product }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { recentlyAdded = nil }
        }
    }
}

// MARK: - Toast
struct AddedProductToast: View {
    let product: Product
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Text(product.emoji).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ditambahkan! ✓")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                    Text(product.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(product.formattedPrice)
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.15))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.5), lineWidth: 1))
            )
            .padding(.bottom, 16)
        }
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
