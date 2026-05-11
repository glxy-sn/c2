import SwiftUI

// MARK: - Cart Panel (right sidebar)
struct CartPanelView: View {
    @ObservedObject var cartManager: CartManager
    let onCheckout: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keranjang Belanja")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(cartManager.totalItems) item")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                Spacer()
                
                if !cartManager.cartItems.isEmpty {
                    Button(action: { cartManager.clearCart() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundColor(.red.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(white: 0.1))
            
            Divider().background(Color.white.opacity(0.1))
            
            // Items list
            if cartManager.cartItems.isEmpty {
                EmptyCartView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(cartManager.cartItems) { item in
                            CartItemRow(item: item, cartManager: cartManager)
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
            
            Spacer()
            
            // Summary & Checkout
            VStack(spacing: 0) {
                Divider().background(Color.white.opacity(0.1))
                
                // Price breakdown
                VStack(spacing: 8) {
                    HStack {
                        Text("Subtotal (\(cartManager.totalItems) item)")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Spacer()
                        Text(cartManager.formattedTotal)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                    }
                    
                    HStack {
                        Text("Total")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                        Text(cartManager.formattedTotal)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Checkout button
                Button(action: {
                    if !cartManager.cartItems.isEmpty { onCheckout() }
                }) {
                    HStack {
                        Image(systemName: "creditcard.fill")
                        Text("Bayar Sekarang")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        cartManager.cartItems.isEmpty
                            ? Color.gray.opacity(0.3)
                            : Color.green
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .disabled(cartManager.cartItems.isEmpty)
                .animation(.easeInOut, value: cartManager.cartItems.isEmpty)
            }
            .background(Color(white: 0.08))
        }
        .background(Color(white: 0.07))
    }
}

// MARK: - Cart Item Row
struct CartItemRow: View {
    let item: CartItem
    @ObservedObject var cartManager: CartManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Emoji icon
            Text(item.product.emoji)
                .font(.system(size: 28))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
            
            // Name and price
            VStack(alignment: .leading, spacing: 3) {
                Text(item.product.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                Text(item.product.formattedPrice)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Quantity controls
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.formattedSubtotal)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.yellow)
                
                HStack(spacing: 0) {
                    Button(action: { cartManager.decreaseQuantity(for: item) }) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(.white)
                    }
                    
                    Text("\(item.quantity)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28)
                        .background(Color.white.opacity(0.06))
                    
                    Button(action: { cartManager.addProduct(item.product) }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Color.green.opacity(0.8))
                            .foregroundColor(.white)
                    }
                }
                .cornerRadius(6)
                .clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                cartManager.removeItem(item)
            } label: {
                Label("Hapus", systemImage: "trash")
            }
        }
    }
}

// MARK: - Empty state
struct EmptyCartView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cart")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.4))
            Text("Keranjang kosong")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gray)
            Text("Scan produk dan tap kotak deteksi")
                .font(.system(size: 13))
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }
}
