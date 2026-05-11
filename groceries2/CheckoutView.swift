import SwiftUI

struct CheckoutView: View {
    @ObservedObject var cartManager: CartManager
    @Environment(\.dismiss) var dismiss
    
    @State private var paymentMethod: PaymentMethod = .cash
    @State private var cashInput: String = ""
    @State private var isProcessing: Bool = false
    @State private var showSuccess: Bool = false
    
    enum PaymentMethod: String, CaseIterable {
        case cash = "Tunai"
        case qris = "QRIS"
        case debit = "Kartu Debit"
        
        var icon: String {
            switch self {
            case .cash: return "banknote.fill"
            case .qris: return "qrcode"
            case .debit: return "creditcard.fill"
            }
        }
    }
    
    var change: Double {
        guard paymentMethod == .cash,
              let cashAmount = Double(cashInput) else { return 0 }
        return max(0, cashAmount - cartManager.totalPrice)
    }
    
    var formattedChange: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "IDR"
        formatter.currencySymbol = "Rp"
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: change)) ?? "Rp 0"
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.08).ignoresSafeArea()
                
                if showSuccess {
                    SuccessView(total: cartManager.formattedTotal) {
                        cartManager.clearCart()
                        dismiss()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Order summary
                            VStack(alignment: .leading, spacing: 0) {
                                SectionHeader(title: "Ringkasan Pesanan", icon: "list.bullet.rectangle")
                                
                                ForEach(cartManager.cartItems) { item in
                                    HStack {
                                        Text(item.product.emoji)
                                        Text(item.product.name)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text("×\(item.quantity)")
                                            .foregroundColor(.gray)
                                        Text(item.formattedSubtotal)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.yellow)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    
                                    Divider().background(Color.white.opacity(0.06)).padding(.leading, 16)
                                }
                                
                                // Total
                                HStack {
                                    Text("Total Pembayaran")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text(cartManager.formattedTotal)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.green)
                                }
                                .padding(16)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(0)
                            }
                            .background(Color(white: 0.12))
                            .cornerRadius(14)
                            
                            // Payment method
                            VStack(alignment: .leading, spacing: 0) {
                                SectionHeader(title: "Metode Pembayaran", icon: "creditcard")
                                
                                HStack(spacing: 10) {
                                    ForEach(PaymentMethod.allCases, id: \.self) { method in
                                        Button(action: { paymentMethod = method }) {
                                            VStack(spacing: 6) {
                                                Image(systemName: method.icon)
                                                    .font(.system(size: 22))
                                                Text(method.rawValue)
                                                    .font(.system(size: 12, weight: .medium))
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .background(
                                                paymentMethod == method
                                                    ? Color.green.opacity(0.25)
                                                    : Color(white: 0.15)
                                            )
                                            .foregroundColor(paymentMethod == method ? .green : .white)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(
                                                        paymentMethod == method ? Color.green : Color.clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                            .cornerRadius(10)
                                        }
                                    }
                                }
                                .padding(16)
                            }
                            .background(Color(white: 0.12))
                            .cornerRadius(14)
                            
                            // Cash input
                            if paymentMethod == .cash {
                                VStack(alignment: .leading, spacing: 0) {
                                    SectionHeader(title: "Uang Diterima", icon: "banknote")
                                    
                                    VStack(spacing: 12) {
                                        HStack {
                                            Text("Rp")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.gray)
                                            TextField("0", text: $cashInput)
                                                .keyboardType(.numberPad)
                                                .font(.system(size: 24, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                        .padding(14)
                                        .background(Color(white: 0.18))
                                        .cornerRadius(10)
                                        
                                        // Quick amounts
                                        let quickAmounts = [50000, 100000, 50000 * 2 + Int(cartManager.totalPrice / 50000) * 50000]
                                        HStack(spacing: 8) {
                                            ForEach(quickAmounts, id: \.self) { amount in
                                                Button("Rp \(amount/1000)K") {
                                                    cashInput = "\(amount)"
                                                }
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.white.opacity(0.1))
                                                .foregroundColor(.white)
                                                .cornerRadius(6)
                                            }
                                            Spacer()
                                        }
                                        
                                        if !cashInput.isEmpty, let cash = Double(cashInput), cash >= cartManager.totalPrice {
                                            HStack {
                                                Text("Kembalian:")
                                                    .foregroundColor(.gray)
                                                Spacer()
                                                Text(formattedChange)
                                                    .font(.system(size: 20, weight: .bold))
                                                    .foregroundColor(.blue)
                                            }
                                            .padding(12)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(8)
                                        }
                                    }
                                    .padding(16)
                                }
                                .background(Color(white: 0.12))
                                .cornerRadius(14)
                            }
                            
                            // QRIS placeholder
                            if paymentMethod == .qris {
                                VStack(spacing: 12) {
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 100))
                                        .foregroundColor(.white)
                                    Text("Tampilkan QR ke pelanggan")
                                        .font(.system(size: 14))
                                        .foregroundColor(.gray)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(30)
                                .background(Color(white: 0.12))
                                .cornerRadius(14)
                            }
                            
                            // Confirm button
                            Button(action: processPayment) {
                                HStack {
                                    if isProcessing {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("Konfirmasi Pembayaran")
                                            .fontWeight(.bold)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(isPaymentValid ? Color.green : Color.gray.opacity(0.3))
                                .foregroundColor(.white)
                                .cornerRadius(14)
                            }
                            .disabled(!isPaymentValid || isProcessing)
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Pembayaran")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    var isPaymentValid: Bool {
        switch paymentMethod {
        case .cash:
            guard let cash = Double(cashInput) else { return false }
            return cash >= cartManager.totalPrice
        case .qris, .debit:
            return true
        }
    }
    
    func processPayment() {
        isProcessing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isProcessing = false
            withAnimation(.spring()) { showSuccess = true }
            cartManager.checkout()
        }
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.green)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
    }
}

// MARK: - Success View
struct SuccessView: View {
    let total: String
    let onDone: () -> Void
    
    @State private var animate = false
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .scaleEffect(animate ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: animate)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
            }
            
            VStack(spacing: 8) {
                Text("Pembayaran Berhasil!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                Text("Total: \(total)")
                    .font(.system(size: 18))
                    .foregroundColor(.green)
                Text("Terima kasih telah berbelanja 🙏")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button(action: onDone) {
                Text("Transaksi Baru")
                    .font(.system(size: 18, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .onAppear { animate = true }
    }
}
