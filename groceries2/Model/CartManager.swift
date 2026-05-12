import Foundation
import UIKit
import Combine

class CartManager: ObservableObject {
    @Published var cartItems: [CartItem] = []
    @Published var isCheckoutComplete: Bool = false

    // Produk terakhir yang ditambahkan — dipakai BasketManager sebagai
    // fallback label saat TAKE tapi detektor tidak bisa lihat produk (occlusion).
    private(set) var lastAddedProduct: Product? = nil

    var totalPrice: Double {
        cartItems.reduce(0) { $0 + $1.subtotal }
    }

    var formattedTotal: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "IDR"
        f.currencySymbol = "Rp"
        f.maximumFractionDigits = 0
        f.groupingSeparator = "."
        return f.string(from: NSNumber(value: totalPrice)) ?? "Rp \(Int(totalPrice))"
    }

    var totalItems: Int {
        cartItems.reduce(0) { $0 + $1.quantity }
    }

    // MARK: - Add product

    /// Tambah produk berdasarkan objek Product.
    /// Dipakai saat user tap bounding box manual.
    func addProduct(_ product: Product) {
        _addProduct(product)
    }

    /// Tambah produk berdasarkan nama — dipakai BasketManager (PUT gesture).
    /// Return true kalau produk ditemukan di database.
    @discardableResult
    func addProductByName(_ name: String) -> Bool {
        guard let product = findProduct(named: name) else {
            print("[CartManager] ⚠️ PUT: produk '\(name)' tidak ditemukan di database")
            return false
        }
        _addProduct(product)
        return true
    }

    private func _addProduct(_ product: Product) {
        if let idx = cartItems.firstIndex(where: { $0.product.id == product.id }) {
            cartItems[idx].quantity += 1
        } else {
            cartItems.append(CartItem(product: product, quantity: 1))
        }
        lastAddedProduct = product
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        print("[CartManager] ✅ Tambah: \(product.name) — total \(totalItems) item")
    }

    // MARK: - Remove product

    /// Kurangi 1 quantity berdasarkan nama — dipakai BasketManager (TAKE gesture).
    /// Cari produk yang ada di cart, kurangi quantity-nya.
    /// Return nama produk yang berhasil dikurangi, atau nil.
    @discardableResult
    func removeProductByName(_ name: String) -> String? {
        // Coba match nama persis dulu
        if let idx = cartItems.firstIndex(where: { $0.product.name == name }) {
            let productName = cartItems[idx].product.name
            _decreaseAt(idx)
            return productName
        }

        // Fallback: partial match (mengatasi perbedaan kapitalisasi atau spasi)
        if let idx = cartItems.firstIndex(where: {
            $0.product.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains($0.product.name.lowercased())
        }) {
            let productName = cartItems[idx].product.name
            _decreaseAt(idx)
            return productName
        }

        print("[CartManager] ⚠️ TAKE: '\(name)' tidak ada di cart")
        return nil
    }

    /// Kurangi produk terakhir yang ditambahkan — ultimate fallback untuk TAKE
    /// saat detektor tidak bisa identify produk karena occlusion.
    @discardableResult
    func removeLastAdded() -> String? {
        guard let last = lastAddedProduct else { return nil }
        return removeProductByName(last.name)
    }

    // MARK: - Manual controls (dari CartItemRow)

    func decreaseQuantity(for item: CartItem) {
        guard let idx = cartItems.firstIndex(where: { $0.id == item.id }) else { return }
        _decreaseAt(idx)
    }

    func removeItem(_ item: CartItem) {
        cartItems.removeAll { $0.id == item.id }
        print("[CartManager] 🗑 Hapus: \(item.product.name)")
    }

    private func _decreaseAt(_ idx: Int) {
        let name = cartItems[idx].product.name
        if cartItems[idx].quantity > 1 {
            cartItems[idx].quantity -= 1
            print("[CartManager] ➖ Kurangi: \(name) — sisa \(cartItems[idx].quantity)")
        } else {
            cartItems.remove(at: idx)
            print("[CartManager] 🗑 Hapus dari cart: \(name)")
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Helpers

    /// Cari produk di database berdasarkan nama (exact → case-insensitive → partial)
    func findProduct(named name: String) -> Product? {
        let all = Array(ProductDatabase.products.values)

        // 1. Exact match
        if let p = all.first(where: { $0.name == name }) { return p }

        // 2. Case-insensitive exact
        if let p = all.first(where: { $0.name.lowercased() == name.lowercased() }) { return p }

        // 3. Partial contains (product name contains detection name, or vice versa)
        if let p = all.first(where: {
            $0.name.lowercased().contains(name.lowercased()) ||
            name.lowercased().contains($0.name.lowercased())
        }) { return p }

        return nil
    }

    /// Semua nama produk yang ada di cart saat ini
    var currentProductNames: [String] {
        cartItems.map { $0.product.name }
    }

    // MARK: - Clear / Checkout

    func clearCart() {
        cartItems = []
        lastAddedProduct = nil
        isCheckoutComplete = false
        print("[CartManager] 🛒 Cart dikosongkan")
    }

    func checkout() {
        isCheckoutComplete = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
