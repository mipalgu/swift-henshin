//
//  ApplicationSession.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase

/// The state of one application of a unit or rule to a resource.
///
/// A session owns an indexed copy of the resource's objects, which it keeps in step with
/// the resource as rules change it, together with the caches and records of the
/// application. Matching runs on that copy without calling into the resource; each rule
/// application changes the resource in one call.
struct ApplicationSession: Sendable {
    /// The module whose units are applied.
    let module: HenshinModule
    /// The options of the application.
    let options: EngineOptions
    /// The resource that the application changes.
    let resource: Resource
    /// The indexed objects of the resource.
    var graph: ModelGraph
    /// The cache of type conformance and reference information.
    var types = TypeCatalogue()
    /// The compiled rules, by unit identity.
    var compiled: [UnitID: CompiledRule] = [:]
    /// The evaluator of AQL queries, created when first needed.
    var evaluator: ExpressionEvaluator?
    /// The random number generator for non-deterministic application.
    var random: SeededGenerator
    /// The rule applications that took effect, in order.
    var applied: [RuleApplication] = []
    /// What the engine noticed during the application.
    var diagnostics: [SourceDiagnostic] = []
    /// Statistics of the search for matches.
    var statistics = MatchStatistics()

    #if os(WASI)
    /// The number of candidates that the search examines before it lets other tasks run.
    ///
    /// WebAssembly has no tail calls, so each asynchronous call that completes without
    /// suspending deepens the call stack until the task next suspends. Suspending at regular
    /// intervals keeps the stack of a search through a large model bounded.
    static let candidatesBetweenSuspensions = 256
    #endif

    /// Creates a session.
    ///
    /// - Parameters:
    ///   - module: The module whose units are applied.
    ///   - resource: The resource to change.
    ///   - options: The options of the application.
    init(module: HenshinModule, resource: Resource, options: EngineOptions) async {
        self.init(module: module, resource: resource, objects: await resource.getAllObjects(), options: options)
    }

    /// Creates a session whose index holds given objects of the resource.
    ///
    /// - Parameters:
    ///   - module: The module whose units are applied.
    ///   - resource: The resource to change.
    ///   - objects: The objects of the resource, in order.
    ///   - options: The options of the application.
    init(module: HenshinModule, resource: Resource, objects: [any EObject], options: EngineOptions) {
        self.module = module
        self.options = options
        self.resource = resource
        graph = ModelGraph(objects: objects)
        random = Self.generator(for: options)
        if graph.foreignObjectCount > 0 {
            diagnostics.append(
                .henshin(
                    .information, .foreignObject,
                    "\(graph.foreignObjectCount) object(s) of the resource are not dynamic objects and take no part in matching"))
        }
    }

    /// The random number generator with which an application starts.
    ///
    /// - Parameter options: The options of the application.
    /// - Returns: A generator seeded with ``EngineOptions/randomSeed``, or from the system's
    ///   source of randomness if there is no seed.
    static func generator(for options: EngineOptions) -> SeededGenerator {
        SeededGenerator(seed: options.randomSeed ?? UInt64.random(in: UInt64.min...UInt64.max))
    }

    // MARK: - Rules

    /// The compiled form of a rule.
    ///
    /// - Parameters:
    ///   - rule: The rule.
    ///   - unit: The identity of its unit, under which the compiled rule is cached, if any.
    /// - Returns: The compiled rule.
    /// - Throws: ``HenshinError`` if the rule is malformed.
    mutating func compile(_ rule: Rule, unit: UnitID?) throws(HenshinError) -> CompiledRule {
        if let unit, let known = compiled[unit] { return known }
        let result = try CompiledRule(rule, options: options, types: &types)
        if let unit { compiled[unit] = result }
        return result
    }

    // MARK: - Expressions

    /// Evaluates an expression with parameter values.
    ///
    /// - Parameters:
    ///   - expression: The expression.
    ///   - parameters: The parameter values.
    /// - Returns: The value of the expression.
    /// - Throws: ``HenshinError/unboundParameter(expression:parameter:)`` if a parameter it
    ///   refers to has no value, or an evaluation error.
    mutating func evaluate(_ expression: CompiledExpression, _ parameters: ParameterBindings) async throws(HenshinError)
        -> (any EcoreValue)?
    {
        if let literal = expression.literal { return literal.ecoreValue }
        if let unbound = expression.variables.first(where: { !parameters.isBound($0) }) {
            throw .unboundParameter(expression: expression.source, parameter: unbound)
        }
        if let parameter = expression.parameter { return parameters.value(parameter) }
        var values: [String: SendableValue] = [:]
        for name in expression.variables {
            let value = parameters.value(name)
            if let id = value as? EUUID, let object = graph.object(id) {
                values[name] = SendableValue(value: object)
            } else {
                values[name] = SendableValue(value: value)
            }
        }
        let evaluator: ExpressionEvaluator
        if let existing = self.evaluator {
            evaluator = existing
        } else {
            evaluator = await MainActor.run { ExpressionEvaluator() }
            self.evaluator = evaluator
        }
        statistics.queries += 1
        return try await evaluator.evaluate(expression, values: values)
    }

    /// Evaluates a Boolean expression.
    ///
    /// - Parameters:
    ///   - expression: The expression.
    ///   - parameters: The parameter values.
    /// - Returns: `true` only if the expression yields `true`.
    /// - Throws: The errors of ``evaluate(_:_:)``.
    mutating func holds(_ expression: CompiledExpression, _ parameters: ParameterBindings) async throws(HenshinError) -> Bool {
        (try await evaluate(expression, parameters) as? Bool) ?? false
    }

    // MARK: - Finding matches

    /// Finds matches of a rule.
    ///
    /// A node fixed to an object matches only that object, and binds the parameter that
    /// shares its name, if any, to it.
    ///
    /// On WebAssembly, every search first lets other tasks run. WebAssembly has no tail
    /// calls, so each asynchronous call that completes without suspending deepens the call
    /// stack until the task next suspends. A caller that finds matches and applies rules
    /// again and again, such as the exploration of a state space, would otherwise exhaust
    /// the stack even if each search examines few candidates.
    ///
    /// - Parameters:
    ///   - rule: The compiled rule.
    ///   - parameters: The parameter values given; object parameters fix their nodes.
    ///   - fixed: The objects that left-hand side nodes are fixed to, by node identity
    ///     (default: none).
    ///   - limit: The largest number of matches to find, or `nil` for all.
    /// - Returns: The matches, each with the matches of its multi-rules.
    /// - Throws: ``HenshinError`` if an expression cannot be evaluated.
    mutating func findMatches(
        _ rule: CompiledRule, parameters: ParameterBindings, fixing fixed: [NodeID: EUUID] = [:], limit: Int?
    ) async throws -> [MatchInstance] {
        #if os(WASI)
        await Task.yield()
        #endif
        statistics.searches += 1
        var state = MatchState(size: rule.lhs.nodes.count, parameters: parameters)
        for (position, node) in rule.lhs.nodes.enumerated() {
            if let id = fixed[node.id] {
                guard graph.contains(id) else { return [] }
                if let name = node.parameter { state.parameters.bind(name, id) }
                state.binding[position] = id
                continue
            }
            guard let name = node.parameter, let id = parameters.value(name) as? EUUID else { continue }
            guard graph.contains(id) else { return [] }
            state.binding[position] = id
        }
        state.pending = rule.conditions.indices.map { .condition($0) }
        guard try await resolvePending(rule.lhs, &state, conditions: rule.conditions) else { return [] }
        var results: [MatchInstance] = []
        let plan = makePlan(rule.lhs, bound: Set(state.binding.indices.filter { state.binding[$0] != nil }))
        _ = try await search(
            rule.lhs, plan, 0, &state, conditions: rule.conditions, goal: .collect(rule: rule, limit: limit, top: true),
            results: &results)
        return results
    }

    /// What a search is for.
    enum SearchGoal {
        /// Whether any match exists.
        case exists
        /// Matches of a rule, completed with their multi-matches, up to a limit.
        case collect(rule: CompiledRule, limit: Int?, top: Bool)
    }

    /// Orders the nodes of a pattern for the search.
    ///
    /// Bound nodes come first. Then, repeatedly, the unbound node with the fewest expected
    /// candidates is chosen: a node reachable through a reference from a node already
    /// placed expects few (one through a single-valued reference, its opposite or a
    /// containment), any other node as many as there are objects of its type. A node is
    /// reached through a reference rather than from its type when both promise as few
    /// candidates. Ties between nodes go to the node with more attribute constraints and
    /// then to the earlier node.
    ///
    /// - Parameters:
    ///   - pattern: The pattern.
    ///   - bound: The positions of the nodes bound before the search.
    /// - Returns: The plan.
    mutating func makePlan(_ pattern: CompiledPattern, bound: Set<Int>) -> [PlanStep] {
        let count = pattern.nodes.count
        var placed = Array(repeating: false, count: count)
        var order: [(node: Int, source: CandidateSource)] = []
        for node in bound.sorted() {
            order.append((node, .fixed))
            placed[node] = true
        }
        let manyCost = 3
        var extentCost: [Int: Int] = [:]
        while order.count < count {
            var best: (node: Int, cost: Int, source: CandidateSource)?
            for node in 0..<count where !placed[node] {
                let patternNode = pattern.nodes[node]
                var cost: Int
                if let known = extentCost[node] {
                    cost = known
                } else {
                    cost = graph.instanceCount(of: patternNode.type, types: &types)
                    extentCost[node] = cost
                }
                var source = CandidateSource.extent
                for edgeIndex in pattern.incident[node] {
                    let edge = pattern.edges[edgeIndex]
                    if edge.source == node, edge.target != node, placed[edge.target] {
                        let info = types.reference(edge.reference, of: patternNode.type)
                        let candidates = info.map { $0.oppositeIsSingle || $0.reference.containment } == true ? 1 : manyCost
                        if candidates <= cost {
                            cost = candidates
                            source = .backward(from: edge.target, reference: edge.reference)
                        }
                    } else if edge.target == node, edge.source != node, placed[edge.source] {
                        let info = types.reference(edge.reference, of: pattern.nodes[edge.source].type)
                        let candidates = info.map { !$0.reference.isMany } == true ? 1 : manyCost
                        if candidates <= cost {
                            cost = candidates
                            source = .forward(from: edge.source, reference: edge.reference)
                        }
                    }
                }
                if let current = best {
                    let better =
                        cost < current.cost
                        || (cost == current.cost && patternNode.attributes.count > pattern.nodes[current.node].attributes.count)
                    if !better { continue }
                }
                best = (node, cost, source)
            }
            guard let chosen = best else { break }
            order.append((chosen.node, chosen.source))
            placed[chosen.node] = true
        }
        var position = Array(repeating: 0, count: count)
        for (index, step) in order.enumerated() { position[step.node] = index }
        return order.enumerated().map { index, step in
            let checks = pattern.incident[step.node].filter { edgeIndex in
                let edge = pattern.edges[edgeIndex]
                let other = edge.source == step.node ? edge.target : edge.source
                return position[other] <= index
            }
            return PlanStep(node: step.node, source: step.source, edgeChecks: checks)
        }
    }

    /// Searches for matches by binding the nodes of a plan one after another.
    ///
    /// - Parameters:
    ///   - pattern: The pattern.
    ///   - plan: The search plan.
    ///   - depth: The plan step to bind.
    ///   - state: The search state, restored before the function returns.
    ///   - conditions: The attribute conditions of the rule, if the pattern is a left-hand side.
    ///   - goal: What the search is for.
    ///   - results: Receives the matches found for a collecting goal.
    /// - Returns: `true` if the search should stop: a match exists, or the limit is reached.
    /// - Throws: ``HenshinError`` if an expression cannot be evaluated.
    mutating func search(
        _ pattern: CompiledPattern, _ plan: [PlanStep], _ depth: Int, _ state: inout MatchState,
        conditions: [CompiledExpression], goal: SearchGoal, results: inout [MatchInstance]
    ) async throws -> Bool {
        if depth == plan.count {
            return try await complete(pattern, &state, conditions: conditions, goal: goal, results: &results)
        }
        try Task.checkCancellation()
        let step = plan[depth]
        let node = step.node
        var candidates: [EUUID]
        switch step.source {
        case .fixed:
            candidates = state.binding[node].map { [$0] } ?? []
        case .extent:
            candidates = graph.instances(of: pattern.nodes[node].type, types: &types)
        case .forward(let from, let reference):
            candidates = state.binding[from].map { graph.targets(of: $0, reference) } ?? []
        case .backward(let from, let reference):
            candidates = state.binding[from].map { graph.sources(of: $0, reference) } ?? []
        }
        if !options.deterministic, candidates.count > 1 { candidates.shuffle(using: &random) }
        let saved = state
        for candidate in candidates {
            statistics.candidates += 1
            #if os(WASI)
            if statistics.candidates.isMultiple(of: Self.candidatesBetweenSuspensions) { await Task.yield() }
            #endif
            if try await admit(candidate, step, pattern, &state, conditions: conditions, goal: goal) {
                if try await search(pattern, plan, depth + 1, &state, conditions: conditions, goal: goal, results: &results) {
                    state = saved
                    return true
                }
            }
            state = saved
        }
        return false
    }

    /// Binds a candidate to a node if it satisfies every constraint that can be checked.
    ///
    /// - Returns: `true` if the candidate was bound.
    private mutating func admit(
        _ candidate: EUUID, _ step: PlanStep, _ pattern: CompiledPattern, _ state: inout MatchState,
        conditions: [CompiledExpression], goal: SearchGoal
    ) async throws -> Bool {
        let position = step.node
        let node = pattern.nodes[position]
        guard let object = graph.object(candidate), types.conforms(object.eClass, to: node.type) else { return false }
        let isMapped = state.mapped.contains(position)
        if pattern.injective, !isMapped, state.used.contains(candidate) { return false }
        if let parameter = node.parameter {
            if !state.parameters.isBound(parameter) {
                state.parameters.bind(parameter, candidate)
            } else if let bound = state.parameters.value(parameter) as? EUUID, bound != candidate {
                return false
            }
        }
        state.binding[position] = candidate
        for edgeIndex in step.edgeChecks {
            let edge = pattern.edges[edgeIndex]
            guard let source = state.binding[edge.source], let target = state.binding[edge.target],
                graph.hasEdge(source, edge.reference, target)
            else { return false }
        }
        for (index, check) in node.attributes.enumerated() {
            let actual = graph.attribute(of: candidate, check.feature)
            if let literal = check.expression.literal {
                guard ValueSemantics.equal(actual, ValueSemantics.cast(literal.ecoreValue, to: check.feature)) else { return false }
            } else if let parameter = check.expression.parameter, !state.parameters.isBound(parameter) {
                state.parameters.bind(parameter, actual)
            } else if check.expression.isEvaluable(with: state.parameters) {
                let expected = try await evaluate(check.expression, state.parameters)
                guard ValueSemantics.equal(actual, ValueSemantics.cast(expected, to: check.feature)) else { return false }
            } else {
                state.pending.append(.attribute(node: position, check: index))
            }
        }
        if case .collect(let rule, _, true) = goal, rule.checkDangling, !rule.nodesSharedWithMultiRules.contains(position),
            rule.deletedNodes.contains(position)
        {
            let ends = graph.outgoing(candidate).count + graph.incoming(candidate).count
            if ends > rule.deletedReferenceEnds[position, default: 0] { return false }
        }
        state.used.insert(candidate)
        return try await resolvePending(pattern, &state, conditions: conditions)
    }

    /// Evaluates the waiting checks whose parameters now have values.
    ///
    /// - Returns: `false` if one of them fails.
    private mutating func resolvePending(
        _ pattern: CompiledPattern, _ state: inout MatchState, conditions: [CompiledExpression]
    ) async throws -> Bool {
        guard !state.pending.isEmpty else { return true }
        var remaining: [PendingCheck] = []
        for check in state.pending {
            switch check {
            case .condition(let index):
                guard conditions[index].isEvaluable(with: state.parameters) else {
                    remaining.append(check)
                    continue
                }
                guard try await holds(conditions[index], state.parameters) else { return false }
            case .attribute(let node, let index):
                let attribute = pattern.nodes[node].attributes[index]
                guard attribute.expression.isEvaluable(with: state.parameters), let object = state.binding[node] else {
                    remaining.append(check)
                    continue
                }
                let expected = try await evaluate(attribute.expression, state.parameters)
                let actual = graph.attribute(of: object, attribute.feature)
                guard ValueSemantics.equal(actual, ValueSemantics.cast(expected, to: attribute.feature)) else { return false }
            }
        }
        state.pending = remaining
        return true
    }

    /// Finishes a match whose nodes are all bound.
    private mutating func complete(
        _ pattern: CompiledPattern, _ state: inout MatchState, conditions: [CompiledExpression], goal: SearchGoal,
        results: inout [MatchInstance]
    ) async throws -> Bool {
        if let waiting = state.pending.first {
            let expression: CompiledExpression
            switch waiting {
            case .condition(let index): expression = conditions[index]
            case .attribute(let node, let index): expression = pattern.nodes[node].attributes[index].expression
            }
            let missing = expression.variables.first { !state.parameters.isBound($0) } ?? ""
            throw HenshinError.unboundParameter(expression: expression.source, parameter: missing)
        }
        guard try await holds(pattern.formula, host: state) else { return false }
        switch goal {
        case .exists:
            return true
        case .collect(let rule, let limit, let top):
            var binding: [NodeID: EUUID] = [:]
            for (position, node) in pattern.nodes.enumerated() { binding[node.id] = state.binding[position] }
            var instance = MatchInstance(binding: binding, parameters: state.parameters)
            if !rule.multiRules.isEmpty {
                instance.multiMatches = try await multiMatches(of: rule, kernel: state)
            }
            if top, rule.checkDangling, !danglingConditionHolds(rule, instance) { return false }
            results.append(instance)
            return limit.map { results.count >= $0 } ?? false
        }
    }

    /// Whether an application condition holds for a match of its host pattern.
    private mutating func holds(_ formula: CompiledFormula, host: MatchState) async throws -> Bool {
        switch formula {
        case .true:
            return true
        case .not(let child):
            return !(try await holds(child, host: host))
        case .and(let left, let right):
            guard try await holds(left, host: host) else { return false }
            return try await holds(right, host: host)
        case .or(let left, let right):
            if try await holds(left, host: host) { return true }
            return try await holds(right, host: host)
        case .xor(let left, let right):
            let first = try await holds(left, host: host)
            return first != (try await holds(right, host: host))
        case .condition(let condition):
            statistics.conditionChecks += 1
            var state = MatchState(size: condition.pattern.nodes.count, parameters: host.parameters)
            if condition.pattern.injective { state.used = host.used }
            for mapping in condition.mappings {
                guard let object = host.binding[mapping.host] else { continue }
                if let prior = state.binding[mapping.image], prior != object { return false }
                state.binding[mapping.image] = object
                state.mapped.insert(mapping.image)
            }
            let plan = makePlan(condition.pattern, bound: state.mapped)
            var unused: [MatchInstance] = []
            return try await search(condition.pattern, plan, 0, &state, conditions: [], goal: .exists, results: &unused)
        }
    }

    /// Finds the matches of the multi-rules of a rule that extend a kernel match.
    private mutating func multiMatches(of rule: CompiledRule, kernel: MatchState) async throws -> [[MatchInstance]] {
        var all: [[MatchInstance]] = []
        for (multi, mappings) in rule.multiRules {
            var parameters = ParameterBindings()
            for parameter in multi.rule.parameters where kernel.parameters.isBound(parameter.name) {
                parameters.bind(parameter.name, kernel.parameters.value(parameter.name))
            }
            var state = MatchState(size: multi.lhs.nodes.count, parameters: parameters)
            if multi.lhs.injective { state.used = kernel.used }
            for mapping in mappings {
                state.binding[mapping.image] = kernel.binding[mapping.host]
                state.mapped.insert(mapping.image)
            }
            state.pending = multi.conditions.indices.map { .condition($0) }
            var found: [MatchInstance] = []
            if try await resolvePending(multi.lhs, &state, conditions: multi.conditions) {
                let plan = makePlan(multi.lhs, bound: state.mapped)
                _ = try await search(
                    multi.lhs, plan, 0, &state, conditions: multi.conditions,
                    goal: .collect(rule: multi, limit: nil, top: false), results: &found)
            }
            all.append(found)
        }
        return all
    }

    /// Whether deleting the objects of an amalgamated match leaves no dangling reference.
    ///
    /// Every reference that starts or ends at a deleted object must itself be deleted by
    /// the kernel rule or one of the multi-rule applications, the opposite of a deleted
    /// reference included.
    mutating func danglingConditionHolds(_ rule: CompiledRule, _ instance: MatchInstance) -> Bool {
        var objects = Set<EUUID>()
        var edges = Set<EdgeKey>()
        collectDeletions(rule, instance, objects: &objects, edges: &edges)
        for object in objects {
            for edge in graph.outgoing(object) where !edges.contains(edge) { return false }
            for edge in graph.incoming(object) where !edges.contains(EdgeKey(source: edge.source, reference: edge.reference, target: object)) {
                return false
            }
        }
        return true
    }

    /// Collects the objects and references that an amalgamated match deletes.
    private mutating func collectDeletions(
        _ rule: CompiledRule, _ instance: MatchInstance, objects: inout Set<EUUID>, edges: inout Set<EdgeKey>
    ) {
        for position in rule.deletedNodes {
            if let object = instance.binding[rule.lhs.nodes[position].id] { objects.insert(object) }
        }
        for edge in rule.deletedEdges {
            guard let source = instance.binding[rule.lhs.nodes[edge.source].id],
                let target = instance.binding[rule.lhs.nodes[edge.target].id]
            else { continue }
            edges.insert(EdgeKey(source: source, reference: edge.reference, target: target))
            if let eClass = graph.object(source)?.eClass, let opposite = types.reference(edge.reference, of: eClass)?.oppositeName {
                edges.insert(EdgeKey(source: target, reference: opposite, target: source))
            }
        }
        for (index, multi) in rule.multiRules.enumerated() where index < instance.multiMatches.count {
            for match in instance.multiMatches[index] {
                collectDeletions(multi.rule, match, objects: &objects, edges: &edges)
            }
        }
    }
}
