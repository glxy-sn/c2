import Foundation
import Combine

class CartManager: ObservableObject {
    @Published var cartItems: [CartItem] = []
    @Published var isCheckoutComplete: Bool = false
    
    // Detected products set (to avoid duplicating rapid-fire detections)
    private var confirmedProductIDs: Set<Int> = []
    
    var totalPrice: Double {
        cartItems.reduce(0) { $0 + $1.subtotal }
    }
    
    var formattedTotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "IDR"
        formatter.currencySymbol = "Rp"
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: totalPrice)) ?? "Rp \(Int(totalPrice))"
    }
    
    var totalItems: Int {
        cartItems.reduce(0) { $0 + $1.quantity }
    }
    
    // MARK: - Add product (called when user taps detected item)
    func addProduct(_ product: Product) {
        if let idx = cartItems.firstIndex(where: { $0.product.id == product.id }) {
            cartItems[idx].quantity += 1
        } else {
            cartItems.append(CartItem(product: product, quantity: 1))
        }
        // Haptic
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    // MARK: - Remove one quantity
    func decreaseQuantity(for item: CartItem) {
        if let idx = cartItems.firstIndex(where: { $0.id == item.id }) {
            if cartItems[idx].quantity > 1 {
                cartItems[idx].quantity -= 1
            } else {
                cartItems.remove(at: idx)
            }
        }
    }
    
    // MARK: - Remove entirely
    func removeItem(_ item: CartItem) {
        cartItems.removeAll { $0.id == item.id }
    }
    
    // MARK: - Clear cart
    func clearCart() {
        cartItems = []
        confirmedProductIDs = []
        isCheckoutComplete = false
    }
    
    // MARK: - Checkout
    func checkout() {
        isCheckoutComplete = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

import UIKit
