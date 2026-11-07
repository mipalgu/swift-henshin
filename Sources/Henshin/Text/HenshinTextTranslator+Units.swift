//
//  HenshinTextTranslator+Units.swift
//  Henshin
//
//  Copyright © 2026 Rene Hexel. All rights reserved.
//
import EMFBase

/// The translation of Henshin Text units.
///
/// A unit whose elements are a sequence of calls becomes a sequential unit; a unit with a
/// single control structure becomes a unit of that kind. Every block that is not a single
/// call, such as a nested loop in a sequence or a sequence in a branch, becomes a unit of
/// its own, named after the enclosing unit as Henshin names it (for example
/// `buildGridSequence0_1`), with the parameters of the enclosing unit, to which it is
/// connected parameter by parameter.
extension HenshinTextTranslator {
    /// Translates a unit and the units of its nested blocks.
    ///
    /// - Parameters:
    ///   - text: The unit.
    ///   - id: The identity of the unit.
    ///   - parameters: The translated parameters of the unit.
    mutating func translateUnit(_ text: TextUnit, id: UnitID, parameters: [UnitParameter]) {
        let scope = Set(parameters.map(\.name))
        for (index, parameter) in text.parameters.enumerated() where text.parameters[..<index].contains(where: { $0.name.text == parameter.name.text }) {
            report(.error, .duplicateName, "A parameter named '\(parameter.name.text)' is already declared", at: parameter.name.range)
        }
        units[id.rawValue] = unit(named: text.name.text, id: id, parameters: parameters, elements: text.elements, level: 0, scope: scope, range: text.range)
    }

    /// Translates the elements of a unit or block into a unit.
    private mutating func unit(
        named name: String, id: UnitID, parameters: [UnitParameter], elements: [TextUnitElement], level: Int, scope: Set<String>,
        range: SourceRange
    ) -> TransformationUnit {
        var mappings: [ParameterMapping] = []
        let kind: UnitKind
        if isSequence(elements) || elements.isEmpty {
            var subUnits: [UnitID] = []
            var strict: [TextOption] = []
            var rollback: [TextOption] = []
            for (index, element) in elements.enumerated() {
                switch element {
                case .call(let call):
                    if let callee = self.call(call, from: id, scope: scope, into: &mappings) { subUnits.append(callee) }
                case .strict(let option):
                    strict.append(option)
                case .rollback(let option):
                    rollback.append(option)
                case .block(let inner, let blockRange):
                    subUnits.append(
                        auxiliary(name + HenshinTextConstants.AuxiliaryUnit.sequence + "\(level)_\(index)", parent: id, parameters: parameters,
                            elements: inner, level: level + 1, scope: scope, range: blockRange, into: &mappings))
                default:
                    subUnits.append(
                        auxiliary(name + HenshinTextConstants.AuxiliaryUnit.sequence + "\(level)_\(index)", parent: id, parameters: parameters,
                            elements: [element], level: level + 1, scope: scope, range: element.range, into: &mappings))
                }
            }
            for (options, keyword) in [(strict, HenshinTextConstants.Keyword.strict), (rollback, HenshinTextConstants.Keyword.rollback)] where options.count > 1 {
                report(.error, .repeatedElement, "'\(keyword)' can only be given once", at: options[1].range)
            }
            kind = .sequential(
                subUnits, strict: strict.first?.value ?? HenshinConstants.Defaults.sequentialStrict,
                rollback: rollback.first?.value ?? HenshinConstants.Defaults.sequentialRollback)
        } else {
            /// Translates a block that stands for one sub-unit.
            func single(_ block: [TextUnitElement], _ infix: String, _ blockRange: SourceRange, _ mappings: inout [ParameterMapping]) -> UnitID? {
                if block.count == 1, case .call(let call) = block[0] { return self.call(call, from: id, scope: scope, into: &mappings) }
                guard !block.isEmpty else { return nil }
                return auxiliary(name + infix, parent: id, parameters: parameters, elements: block, level: level + 1, scope: scope, range: blockRange, into: &mappings)
            }
            /// Shorthand for the infixes of the names of nested units.
            typealias Infix = HenshinTextConstants.AuxiliaryUnit
            switch elements[0] {
            case .conditional(let condition, let then, let otherwise, let elementRange):
                let test = single(condition, Infix.if + "\(level)", elementRange, &mappings)
                let success = single(then, Infix.then + "\(level)", elementRange, &mappings)
                let failure = otherwise.flatMap { single($0, Infix.else + "\(level)", elementRange, &mappings) }
                guard let test, let success else {
                    kind = .sequential([], strict: HenshinConstants.Defaults.sequentialStrict, rollback: HenshinConstants.Defaults.sequentialRollback)
                    break
                }
                kind = .conditional(if: test, then: success, else: failure)
            case .iterated(let iterations, let body, let elementRange):
                let count = javaScript(iterations, scope: scope)
                guard let subUnit = single(body, Infix.iterated + "\(level)", elementRange, &mappings) else {
                    kind = .sequential([], strict: HenshinConstants.Defaults.sequentialStrict, rollback: HenshinConstants.Defaults.sequentialRollback)
                    break
                }
                kind = .iterated(
                    subUnit, iterations: count, strict: HenshinConstants.Defaults.iteratedStrict, rollback: HenshinConstants.Defaults.iteratedRollback)
            case .loop(let body, let elementRange):
                guard let subUnit = single(body, Infix.loop + "\(level)", elementRange, &mappings) else {
                    kind = .sequential([], strict: HenshinConstants.Defaults.sequentialStrict, rollback: HenshinConstants.Defaults.sequentialRollback)
                    break
                }
                kind = .loop(subUnit)
            case .priority(let alternatives, let elementRange):
                kind = .priority(
                    alternatives.enumerated().compactMap { single($0.element, Infix.priority + "\(level)_\($0.offset)", elementRange, &mappings) })
            case .independent(let alternatives, let elementRange):
                kind = .independent(
                    alternatives.enumerated().compactMap { single($0.element, Infix.independent + "\(level)_\($0.offset)", elementRange, &mappings) })
            case .call, .block, .strict, .rollback:
                kind = .sequential([], strict: HenshinConstants.Defaults.sequentialStrict, rollback: HenshinConstants.Defaults.sequentialRollback)
            }
        }
        return TransformationUnit(id: id, name: name, parameters: parameters, parameterMappings: mappings, kind: kind)
    }

    /// Whether the elements of a unit form a sequence: several elements, or any call,
    /// option or block.
    private func isSequence(_ elements: [TextUnitElement]) -> Bool {
        elements.count > 1
            || elements.contains { element in
                switch element {
                case .call, .strict, .rollback, .block: return true
                default: return false
                }
            }
    }

    /// Creates the unit of a nested block, connected to its parent by parameters of the same
    /// names.
    private mutating func auxiliary(
        _ requestedName: String, parent: UnitID, parameters: [UnitParameter], elements: [TextUnitElement], level: Int, scope: Set<String>,
        range: SourceRange, into mappings: inout [ParameterMapping]
    ) -> UnitID {
        var name = requestedName
        var suffix = 1
        while declarations[name] != nil {
            suffix += 1
            name = "\(requestedName)_\(suffix)"
        }
        let id = UnitID(units.count)
        declarations[name] = (id, [])
        units.append(nil)
        units[id.rawValue] = unit(named: name, id: id, parameters: parameters, elements: elements, level: level, scope: scope, range: range)
        for parameter in parameters {
            appendUnique(ParameterMapping(source: ParameterReference(unit: parent, name: parameter.name), target: ParameterReference(unit: id, name: parameter.name)), to: &mappings)
            appendUnique(ParameterMapping(source: ParameterReference(unit: id, name: parameter.name), target: ParameterReference(unit: parent, name: parameter.name)), to: &mappings)
        }
        return id
    }

    /// Resolves a call and records the parameter mappings that its arguments imply.
    ///
    /// The arguments are matched in order with the parameters of the called rule or unit
    /// that are not variables, and each pair is connected in both directions.
    ///
    /// - Returns: The identity of the called rule or unit, or `nil` if there is none of the
    ///   name.
    private mutating func call(_ call: TextCall, from unit: UnitID, scope: Set<String>, into mappings: inout [ParameterMapping]) -> UnitID? {
        guard let callee = declarations[call.callee.text] else {
            report(.error, .unknownName, "No rule or unit named '\(call.callee.text)' is declared", at: call.callee.range)
            return nil
        }
        let passed = callee.parameters.filter { $0.kind != .var }
        if passed.count != call.arguments.count {
            report(
                .error, .argumentCount,
                "'\(call.callee.text)' expects \(passed.count) argument(s) but receives \(call.arguments.count)", at: call.range)
        }
        for (argument, parameter) in zip(call.arguments, passed) {
            guard scope.contains(argument.text) else {
                report(.error, .unknownName, "'\(argument.text)' is not a parameter", at: argument.range)
                continue
            }
            let own = ParameterReference(unit: unit, name: argument.text)
            let theirs = ParameterReference(unit: callee.id, name: parameter.name.text)
            appendUnique(ParameterMapping(source: own, target: theirs), to: &mappings)
            appendUnique(ParameterMapping(source: theirs, target: own), to: &mappings)
        }
        return callee.id
    }

    /// Appends a parameter mapping unless it is already there.
    private func appendUnique(_ mapping: ParameterMapping, to mappings: inout [ParameterMapping]) {
        if !mappings.contains(mapping) { mappings.append(mapping) }
    }
}
