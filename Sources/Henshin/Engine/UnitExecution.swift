//
//  UnitExecution.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import ECore
import EMFBase
import Foundation

/// A state of the model and of the session to which a unit can return.
struct Checkpoint: Sendable {
    /// The state of the resource.
    let snapshot: ResourceSnapshot
    /// The number of rule applications recorded when the checkpoint was taken.
    let appliedCount: Int
}

extension ApplicationSession {
    /// Records the current state so that it can be restored.
    ///
    /// - Returns: The checkpoint.
    func checkpoint() async -> Checkpoint {
        Checkpoint(snapshot: await resource.snapshot(), appliedCount: applied.count)
    }

    /// Returns the model and the record of applications to a checkpoint.
    ///
    /// - Parameter checkpoint: The checkpoint.
    mutating func restore(_ checkpoint: Checkpoint) async {
        await resource.restore(checkpoint.snapshot)
        graph = ModelGraph(objects: checkpoint.snapshot.objects)
        applied.removeSubrange(checkpoint.appliedCount...)
    }

    /// Applies a unit with the semantics of Henshin's interpreter.
    ///
    /// - Parameters:
    ///   - id: The identity of the unit.
    ///   - assignment: The parameter values given to the unit.
    /// - Returns: Whether the unit succeeded and the parameter values afterwards.
    /// - Throws: ``HenshinError`` for missing parameters, malformed units or expressions
    ///   that cannot be evaluated, or `CancellationError`.
    mutating func execute(_ id: UnitID, _ assignment: ParameterBindings) async throws -> (succeeded: Bool, result: ParameterBindings) {
        try Task.checkCancellation()
        guard let unit = module.unit(id) else { throw HenshinError.unknownUnit(id.description) }
        for parameter in unit.parameters where parameter.kind.isRequired && assignment.value(parameter.name) == nil {
            throw HenshinError.missingParameter(unit: unit.name, parameter: parameter.name)
        }
        guard unit.isActivated else { return (true, assignment) }
        switch unit.kind {
        case .rule(let rule):
            let compiled = try compile(rule, unit: id)
            guard let application = try await applyRule(compiled, parameters: assignment) else { return (false, assignment) }
            return (true, ParameterBindings(application.parameters))
        case .independent(let subUnits):
            var result = assignment
            var remaining = subUnits
            var succeeded = false
            while !remaining.isEmpty {
                let index = options.deterministic ? 0 : Int.random(in: remaining.indices, using: &random)
                let subUnit = remaining.remove(at: index)
                let outcome = try await execute(subUnit, arguments(for: subUnit, of: unit, from: result))
                if outcome.succeeded {
                    collect(outcome.result, from: subUnit, of: unit, into: &result)
                    succeeded = true
                    break
                }
            }
            return (succeeded, hidingInputs(of: unit, in: result))
        case .sequential(let subUnits, let strict, let rollback):
            let start = strict && rollback ? await checkpoint() : nil
            var result = assignment
            var succeeded = subUnits.isEmpty
            for subUnit in subUnits {
                let outcome = try await execute(subUnit, arguments(for: subUnit, of: unit, from: result))
                if outcome.succeeded {
                    succeeded = true
                    collect(outcome.result, from: subUnit, of: unit, into: &result)
                } else if strict {
                    succeeded = false
                    if let start { await rollBack(unit, to: start) }
                    break
                }
            }
            return (succeeded, hidingInputs(of: unit, in: result))
        case .conditional(let condition, let then, let otherwise):
            let start = await checkpoint()
            var result = assignment
            let succeeded: Bool
            let test = try await execute(condition, arguments(for: condition, of: unit, from: result))
            if test.succeeded {
                collect(test.result, from: condition, of: unit, into: &result)
                let branch = try await execute(then, arguments(for: then, of: unit, from: result))
                if branch.succeeded { collect(branch.result, from: then, of: unit, into: &result) }
                succeeded = branch.succeeded
            } else if let otherwise {
                let branch = try await execute(otherwise, arguments(for: otherwise, of: unit, from: result))
                if branch.succeeded { collect(branch.result, from: otherwise, of: unit, into: &result) }
                succeeded = branch.succeeded
            } else {
                succeeded = true
            }
            if !succeeded { await rollBack(unit, to: start) }
            return (succeeded, hidingInputs(of: unit, in: result))
        case .priority(let subUnits):
            var result = assignment
            var succeeded = false
            for subUnit in subUnits {
                let outcome = try await execute(subUnit, arguments(for: subUnit, of: unit, from: result))
                if outcome.succeeded {
                    collect(outcome.result, from: subUnit, of: unit, into: &result)
                    succeeded = true
                    break
                }
            }
            return (succeeded, hidingInputs(of: unit, in: result))
        case .iterated(let subUnit, let iterations, let strict, let rollback):
            guard let count = try await iterationCount(iterations, of: unit, with: assignment) else {
                return (false, hidingInputs(of: unit, in: assignment))
            }
            let start = strict && rollback ? await checkpoint() : nil
            var result = assignment
            var succeeded = false
            for _ in 0..<max(0, count) {
                let outcome = try await execute(subUnit, arguments(for: subUnit, of: unit, from: result))
                if outcome.succeeded {
                    succeeded = true
                    collect(outcome.result, from: subUnit, of: unit, into: &result)
                } else {
                    if strict {
                        succeeded = false
                        if let start { await rollBack(unit, to: start) }
                    }
                    break
                }
            }
            return (succeeded, hidingInputs(of: unit, in: result))
        case .loop(let subUnit):
            var result = assignment
            var iterations = 0
            while true {
                if let limit = options.iterationLimit, iterations >= limit {
                    diagnostics.append(
                        .henshin(.warning, .iterationLimit, "Loop unit '\(unit.name)' stopped after \(limit) iteration(s)"))
                    break
                }
                let outcome = try await execute(subUnit, arguments(for: subUnit, of: unit, from: result))
                guard outcome.succeeded else { break }
                collect(outcome.result, from: subUnit, of: unit, into: &result)
                iterations += 1
            }
            return (true, hidingInputs(of: unit, in: result))
        }
    }

    /// Undoes the changes made since a checkpoint and records the rollback.
    private mutating func rollBack(_ unit: TransformationUnit, to start: Checkpoint) async {
        let undone = applied.count - start.appliedCount
        await restore(start)
        diagnostics.append(
            .henshin(.information, .rolledBack, "\(unit.kind.className) '\(unit.name)' rolled back \(undone) rule application(s)"))
    }

    /// The parameter values that a unit passes to one of its sub-units.
    private func arguments(for subUnit: UnitID, of unit: TransformationUnit, from values: ParameterBindings) -> ParameterBindings {
        var result = ParameterBindings()
        for mapping in unit.parameterMappings where mapping.target.unit == subUnit && mapping.source.unit == unit.id {
            if values.isBound(mapping.source.name) { result.bind(mapping.target.name, values.value(mapping.source.name)) }
        }
        return result
    }

    /// Takes over the parameter values that a sub-unit passes back to its unit.
    private func collect(_ values: ParameterBindings, from subUnit: UnitID, of unit: TransformationUnit, into result: inout ParameterBindings) {
        for mapping in unit.parameterMappings where mapping.source.unit == subUnit && mapping.target.unit == unit.id {
            if let value = values.value(mapping.source.name) { result.bind(mapping.target.name, value) }
        }
    }

    /// Removes the parameters that the result of a composite unit does not keep.
    private func hidingInputs(of unit: TransformationUnit, in values: ParameterBindings) -> ParameterBindings {
        var result = values
        for parameter in unit.parameters where !parameter.kind.isKeptInResult { result.unbind(parameter.name) }
        return result
    }

    /// The number of iterations that an iterated unit performs.
    ///
    /// - Returns: The number, or `nil` if a parameter that gives it has no numeric value.
    private mutating func iterationCount(
        _ text: String, of unit: TransformationUnit, with values: ParameterBindings
    ) async throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let constant = Int(trimmed) { return constant }
        if unit.parameter(named: trimmed) != nil {
            return values.value(trimmed).flatMap(ValueSemantics.integer)
        }
        let expression = try CompiledExpression(trimmed, variables: Set(unit.parameters.map(\.name)))
        guard let value = try await evaluate(expression, values), let count = ValueSemantics.integer(value) else {
            throw HenshinError.evaluationFailed(expression: text, reason: "the number of iterations is not a number")
        }
        return count
    }
}
