import Foundation

public enum RemoteP256SignatureError: Error {
    case invalidLength
    case invalidScalar
}

/// One low-S encoding for native platform ECDSA signatures before SDK verification.
public enum RemoteP256Signature {
    public static func normalize(_ raw: Data) throws -> Data {
        guard raw.count == 64 else { throw RemoteP256SignatureError.invalidLength }
        let r = Array(raw.prefix(32)), s = Array(raw.suffix(32))
        guard valid(r), valid(s) else { throw RemoteP256SignatureError.invalidScalar }
        var result = Data(r)
        result.append(contentsOf: halfOrder.lexicographicallyPrecedes(s) ? subtract(order, s) : s)
        return result
    }

    private static func valid(_ scalar: [UInt8]) -> Bool {
        scalar.contains(where: { $0 != 0 }) && scalar.lexicographicallyPrecedes(order)
    }

    private static func subtract(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in (0..<32).reversed() {
            let difference = Int(left[index]) - Int(right[index]) - borrow
            result[index] = UInt8(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return result
    }

    private static let order: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ]
    private static let halfOrder: [UInt8] = [
        0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
        0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ]
}
