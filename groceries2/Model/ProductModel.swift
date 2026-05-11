import Foundation

// MARK: - Product Database
struct Product: Identifiable, Hashable {
    let id: Int
    let name: String
    let price: Double
    let emoji: String
    
    var formattedPrice: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "IDR"
        formatter.currencySymbol = "Rp"
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: price)) ?? "Rp \(Int(price))"
    }
}

struct ProductDatabase {
    // Map class index -> Product
    // Sesuaikan harga dengan produk asli
    static let products: [Int: Product] = [
        0:  Product(id: 0,  name: "Chocolatechip Cookie",  price: 12000,  emoji: "🍪"),
        1:  Product(id: 1,  name: "Coca Cola Can 250ml",   price: 8000,   emoji: "🥤"),
        2:  Product(id: 2,  name: "Fanta 500ml",           price: 7000,   emoji: "🧃"),
        3:  Product(id: 3,  name: "Lifebuoy Soap",         price: 5500,   emoji: "🧼"),
        4:  Product(id: 4,  name: "Oreo Biscuit Half Roll",price: 10000,  emoji: "🍫"),
        5:  Product(id: 5,  name: "Pocari Sweat",          price: 8500,   emoji: "💧"),
        6:  Product(id: 6,  name: "Roma Kelapa",           price: 6000,   emoji: "🍘"),
        7:  Product(id: 7,  name: "Sunsilk Shampoo 160ml", price: 18000,  emoji: "🧴"),
        8:  Product(id: 8,  name: "Teh Sosro Kotak",       price: 5000,   emoji: "🍵"),
        9:  Product(id: 9,  name: "Vaseline Lotion 100ml", price: 22000,  emoji: "🧴"),
        10: Product(id: 10, name: "Aqua",                  price: 4000,   emoji: "💧"),
        11: Product(id: 11, name: "Chitato",               price: 12000,  emoji: "🥔"),
        12: Product(id: 12, name: "Indomie",               price: 3500,   emoji: "🍜"),
        13: Product(id: 13, name: "Pepsodent",             price: 15000,  emoji: "🦷"),
        14: Product(id: 14, name: "Shampoo",               price: 15000,  emoji: "🧴"),
        15: Product(id: 15, name: "Tissue",                price: 8000,   emoji: "🧻"),
    ]
    
    static func product(for classIndex: Int) -> Product? {
        return products[classIndex]
    }
}

// MARK: - Cart Item
struct CartItem: Identifiable {
    let id = UUID()
    let product: Product
    var quantity: Int
    
    var subtotal: Double {
        return product.price * Double(quantity)
    }
    
    var formattedSubtotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "IDR"
        formatter.currencySymbol = "Rp"
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: subtotal)) ?? "Rp \(Int(subtotal))"
    }
}

// MARK: - Detection Result
struct DetectionResult {
    let classIndex: Int
    let confidence: Float
    let boundingBox: CGRect  // normalized 0..1
    
    var product: Product? {
        ProductDatabase.product(for: classIndex)
    }
}
