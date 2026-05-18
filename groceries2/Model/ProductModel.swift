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
    // Sesuai urutan kelas model merged dataset (12 kelas)
    // 0: Aqua, 1: Chitato, 2: Fanta, 3: Indomie, 4: Lifebuoy, 5: Oreo
    // 6: Pepsodent, 7: Pocari Sweat, 8: Roma Biskuit Kelapa, 9: Shampoo, 10: Sprite, 11: Tissue
    static let products: [Int: Product] = [
        0:  Product(id: 0,  name: "Aqua",                  price: 4000,   emoji: "💧"),
        1:  Product(id: 1,  name: "Chitato",               price: 12000,  emoji: "🥔"),
        2:  Product(id: 2,  name: "Fanta",                 price: 7000,   emoji: "🧃"),
        3:  Product(id: 3,  name: "Indomie",               price: 3500,   emoji: "🍜"),
        4:  Product(id: 4,  name: "Lifebuoy",              price: 5500,   emoji: "🧼"),
        5:  Product(id: 5,  name: "Oreo",                  price: 10000,  emoji: "🍫"),
        6:  Product(id: 6,  name: "Pepsodent",             price: 15000,  emoji: "🦷"),
        7:  Product(id: 7,  name: "Pocari Sweat",          price: 8500,   emoji: "💧"),
        8:  Product(id: 8,  name: "Roma Biskuit Kelapa",   price: 6000,   emoji: "🍘"),
        9:  Product(id: 9,  name: "Shampoo",               price: 15000,  emoji: "🧴"),
        10: Product(id: 10, name: "Sprite",                price: 7000,   emoji: "🥤"),
        11: Product(id: 11, name: "Tissue",                price: 8000,   emoji: "🧻"),
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
