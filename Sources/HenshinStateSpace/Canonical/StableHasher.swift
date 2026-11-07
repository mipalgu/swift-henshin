//
//  StableHasher.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//

/// A hash function whose results are the same in every process.
///
/// Swift's `Hasher` is seeded anew for each process, which suits hash tables but not
/// certificates that are reported, exported or compared between runs. This hasher applies
/// the 64-bit FNV-1a function to the bytes it is given and mixes the result with the
/// finaliser of SplitMix64.
struct StableHasher: Sendable {
    /// The FNV-1a offset basis.
    private static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325

    /// The FNV-1a prime.
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// The state of the hash.
    private var state: UInt64 = StableHasher.offsetBasis

    /// Creates a hasher in its initial state.
    init() {}

    /// Adds a byte.
    mutating func combine(byte: UInt8) {
        state ^= UInt64(byte)
        state = state &* Self.prime
    }

    /// Adds a 64-bit number, byte by byte.
    mutating func combine(_ value: UInt64) {
        var remaining = value
        for _ in 0..<8 {
            combine(byte: UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }

    /// Adds an integer.
    mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }

    /// Adds a string, followed by a separator so that consecutive strings stay apart.
    mutating func combine(_ text: String) {
        for byte in text.utf8 { combine(byte: byte) }
        combine(byte: 0xFF)
    }

    /// The hash of what was added.
    func finalise() -> UInt64 {
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The hash of a string.
    static func hash(_ text: String) -> UInt64 {
        var hasher = StableHasher()
        hasher.combine(text)
        return hasher.finalise()
    }
}
