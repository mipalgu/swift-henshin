//
//  StateGraph.swift
//  HenshinStateSpace
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// A labelled edge of a state graph, seen from one of its ends.
struct StateGraphLink: Sendable, Hashable {
    /// The hash of the reference name.
    let reference: UInt64
    /// The position of the node at the other end.
    let node: Int
}

/// A model reduced to a labelled graph for comparing states.
///
/// Each object becomes a node labelled with its class and its attribute values; each
/// reference between two objects of the model becomes an edge labelled with the name of the
/// reference. The order of many-valued references and of the objects is not part of the
/// graph, so models that differ only in order are equal states, as in Henshin's state-space
/// tools and GROOVE.
///
/// The graph computes a certificate by colour refinement in the style of Weisfeiler and
/// Leman: isomorphic graphs have equal certificates, and graphs with equal certificates are
/// compared by an exact isomorphism search that uses the refined colours to prune candidates.
struct StateGraph: Sendable {
    /// The identity of the object of each node, in the order of the model.
    let objects: [EUUID]

    /// The hash of the label of each node: its class and attribute values.
    let labels: [UInt64]

    /// The readable label of each node, used when states are compared by identity.
    let labelTexts: [String]

    /// The outgoing edges of each node.
    let outgoing: [[StateGraphLink]]

    /// The incoming edges of each node.
    let incoming: [[StateGraphLink]]

    /// The number of edges.
    let edgeCount: Int

    /// The colour of each node after refinement.
    let colours: [UInt64]

    /// The number of refinement rounds until the colours became stable.
    let rounds: Int

    /// The certificate: equal for isomorphic graphs.
    let certificate: UInt64

    /// Creates the graph of a model.
    ///
    /// - Parameter snapshot: The model.
    init(_ snapshot: ResourceSnapshot) {
        let dynamic = snapshot.objects.compactMap { $0 as? DynamicEObject }
        var positions: [EUUID: Int] = [:]
        for (position, object) in dynamic.enumerated() { positions[object.id] = position }
        var labels: [UInt64] = []
        var labelTexts: [String] = []
        var outgoing = Array(repeating: [StateGraphLink](), count: dynamic.count)
        var incoming = Array(repeating: [StateGraphLink](), count: dynamic.count)
        var edgeCount = 0
        for (position, object) in dynamic.enumerated() {
            var parts = [object.eClass.name]
            for attribute in object.eClass.eAllAttributes.sorted(by: { $0.name < $1.name }) {
                let value = object.eGetWithDefault(attribute).map { String(describing: $0) } ?? "null"
                parts.append("\(attribute.name)=\(value)")
            }
            let text = parts.joined(separator: " ")
            labelTexts.append(text)
            labels.append(StableHasher.hash(text))
            for reference in object.eClass.eAllReferences where !reference.derived {
                let name = StableHasher.hash(reference.name)
                for target in Self.identifiers(object.eGet(reference.name)) {
                    guard let targetPosition = positions[target] else { continue }
                    outgoing[position].append(StateGraphLink(reference: name, node: targetPosition))
                    incoming[targetPosition].append(StateGraphLink(reference: name, node: position))
                    edgeCount += 1
                }
            }
        }
        objects = dynamic.map(\.id)
        self.labels = labels
        self.labelTexts = labelTexts
        self.outgoing = outgoing
        self.incoming = incoming
        self.edgeCount = edgeCount
        let (colours, rounds) = Self.refine(labels: labels, outgoing: outgoing, incoming: incoming)
        self.colours = colours
        self.rounds = rounds
        var hasher = StableHasher()
        hasher.combine(labels.count)
        hasher.combine(edgeCount)
        hasher.combine(rounds)
        for colour in colours.sorted() { hasher.combine(colour) }
        certificate = hasher.finalise()
    }

    /// The number of nodes.
    var nodeCount: Int { labels.count }

    /// Refines node colours until the partition of the nodes stops changing.
    ///
    /// - Returns: The stable colours and the number of rounds that changed the partition.
    static func refine(labels: [UInt64], outgoing: [[StateGraphLink]], incoming: [[StateGraphLink]]) -> ([UInt64], Int) {
        var colours = labels
        var classes = Set(colours).count
        var rounds = 0
        while rounds < labels.count {
            var next: [UInt64] = []
            next.reserveCapacity(colours.count)
            for node in colours.indices {
                var hasher = StableHasher()
                hasher.combine(colours[node])
                for value in outgoing[node].map({ mix($0.reference, colours[$0.node]) }).sorted() { hasher.combine(value) }
                hasher.combine(byte: 0x01)
                for value in incoming[node].map({ mix($0.reference, colours[$0.node]) }).sorted() { hasher.combine(value) }
                next.append(hasher.finalise())
            }
            let nextClasses = Set(next).count
            colours = next
            rounds += 1
            if nextClasses == classes { break }
            classes = nextClasses
        }
        return (colours, rounds)
    }

    /// Combines a reference hash with a colour.
    static func mix(_ reference: UInt64, _ colour: UInt64) -> UInt64 {
        var hasher = StableHasher()
        hasher.combine(reference)
        hasher.combine(colour)
        return hasher.finalise()
    }

    /// The identities that a reference value holds.
    static func identifiers(_ value: (any EcoreValue)?) -> [EUUID] {
        guard let value else { return [] }
        if let id = value as? EUUID { return [id] }
        if let ids = value as? [EUUID] { return ids }
        if let array = value as? EcoreValueArray { return array.values.flatMap { identifiers($0) } }
        if let object = value as? DynamicEObject { return [object.id] }
        return []
    }

    // MARK: - Identity

    /// A description of the graph that names objects by identity, for comparing states
    /// without abstracting from identities.
    var identityForm: IdentityForm {
        var nodes: [String] = []
        var edges: [String] = []
        for (position, object) in objects.enumerated() {
            nodes.append("\(object) \(labelTexts[position])")
            for link in outgoing[position] { edges.append("\(object) \(link.reference) \(objects[link.node])") }
        }
        return IdentityForm(nodes: nodes.sorted(), edges: edges.sorted())
    }

    // MARK: - Isomorphism

    /// Finds an isomorphism to another graph.
    ///
    /// - Parameter other: The other graph.
    /// - Returns: The node of the other graph that each node of this graph maps to, or `nil`
    ///   if the graphs are not isomorphic.
    func isomorphism(to other: StateGraph) -> [Int]? {
        guard nodeCount == other.nodeCount, edgeCount == other.edgeCount, rounds == other.rounds,
            certificate == other.certificate
        else { return nil }
        var buckets: [UInt64: [Int]] = [:]
        for (node, colour) in other.colours.enumerated() { buckets[colour, default: []].append(node) }
        let order = searchOrder()
        var mapping = Array(repeating: -1, count: nodeCount)
        var used = Array(repeating: false, count: nodeCount)
        func consistent(_ node: Int, _ candidate: Int) -> Bool {
            var expected: [Adjacency: Int] = [:]
            for link in outgoing[node] where mapping[link.node] >= 0 || link.node == node {
                let image = link.node == node ? candidate : mapping[link.node]
                expected[Adjacency(outgoing: true, reference: link.reference, node: image), default: 0] += 1
            }
            for link in incoming[node] where mapping[link.node] >= 0 && link.node != node {
                expected[Adjacency(outgoing: false, reference: link.reference, node: mapping[link.node]), default: 0] += 1
            }
            var actual: [Adjacency: Int] = [:]
            for link in other.outgoing[candidate] where used[link.node] || link.node == candidate {
                actual[Adjacency(outgoing: true, reference: link.reference, node: link.node), default: 0] += 1
            }
            for link in other.incoming[candidate] where used[link.node] && link.node != candidate {
                actual[Adjacency(outgoing: false, reference: link.reference, node: link.node), default: 0] += 1
            }
            return expected == actual
        }
        func search(_ index: Int) -> Bool {
            guard index < order.count else { return true }
            let node = order[index]
            for candidate in buckets[colours[node]] ?? [] where !used[candidate] {
                guard consistent(node, candidate) else { continue }
                mapping[node] = candidate
                used[candidate] = true
                if search(index + 1) { return true }
                mapping[node] = -1
                used[candidate] = false
            }
            return false
        }
        return search(0) ? mapping : nil
    }

    /// An order of the nodes for the isomorphism search: rare colours first, then nodes
    /// connected to those already placed.
    func searchOrder() -> [Int] {
        var frequency: [UInt64: Int] = [:]
        for colour in colours { frequency[colour, default: 0] += 1 }
        var placed = Array(repeating: false, count: nodeCount)
        var connections = Array(repeating: 0, count: nodeCount)
        var order: [Int] = []
        order.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            var best = -1
            for node in 0..<nodeCount where !placed[node] {
                if best < 0 {
                    best = node
                    continue
                }
                let key = (-connections[node], frequency[colours[node]] ?? 0, node)
                let bestKey = (-connections[best], frequency[colours[best]] ?? 0, best)
                if key < bestKey { best = node }
            }
            placed[best] = true
            order.append(best)
            for link in outgoing[best] + incoming[best] { connections[link.node] += 1 }
        }
        return order
    }
}

/// An edge between a node and an already mapped node, for checking a candidate mapping.
struct Adjacency: Hashable {
    /// Whether the edge leaves the node.
    let outgoing: Bool
    /// The hash of the reference name.
    let reference: UInt64
    /// The mapped node at the other end.
    let node: Int
}

/// A description of a model that names objects by identity.
struct IdentityForm: Sendable, Hashable {
    /// The objects with their labels, sorted.
    let nodes: [String]
    /// The references between objects, sorted.
    let edges: [String]
}
