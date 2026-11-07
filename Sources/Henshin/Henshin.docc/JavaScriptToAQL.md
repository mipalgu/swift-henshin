# Translating JavaScript Expressions to AQL

Understand how Henshin's JavaScript expressions are evaluated.

## Overview

Henshin writes attribute values, attribute conditions and iteration counts in JavaScript.
``JavaScriptTranslator`` translates the subset of JavaScript that such expressions use into
the Acceleo Query Language, which is then evaluated with `AQL`. Literals and lone
parameter references are evaluated without a query.

Every operation is parenthesised, so AQL's precedence cannot regroup it. Expressions may
refer only to the parameters of their rule or unit; any other name, and any construct
outside the subset, is reported as ``HenshinError/unsupportedExpression(expression:reason:)``
with the reason, rather than being evaluated differently.

| JavaScript | AQL | Notes |
| :-- | :-- | :-- |
| `42`, `2.5`, `"text"`, `'text'`, `true`, `null` | `42`, `2.5`, `'text'`, `true`, `null` | Literals |
| `a` | `a` | Parameter reference |
| `a + b` | `(a + b)` | Addition, or concatenation if either operand is a string |
| `a - b`, `a * b` | `(a - b)`, `(a * b)` | Arithmetic |
| `a / b` | `((a * 1.0) / b)` | Always real division, as in JavaScript |
| `a % b` | `(a mod b)` | Remainder |
| `-a`, `+a` | `(-a)`, `a` | Sign |
| `a == b`, `a === b` | `(a = b)` | Equality |
| `a != b`, `a !== b` | `(a <> b)` | Inequality |
| `a < b`, `<=`, `>`, `>=` | `(a < b)` and so on | Comparison |
| `a && b`, `a \|\| b`, `!a` | `(a and b)`, `(a or b)`, `(not a)` | Logic |
| `c ? a : b` | `(if c then a else b endif)` | Conditional |
| `s.length` | `s.size()` | String length |
| `s.toUpperCase()`, `s.toLowerCase()`, `s.trim()` | `s.toUpper()`, `s.toLower()`, `s.trim()` | Text |
| `s.startsWith(t)`, `s.endsWith(t)`, `s.includes(t)` | `s.startsWith(t)`, `s.endsWith(t)`, `s.contains(t)` | Text tests |
| `s.replace(t, u)` | `s.substituteFirst(t, u)` | Replaces the first occurrence of a text |
| `s.substring(a, b)` | `s.substring((a + 1), b)` | Zero-based start converted to one-based |
| `Math.abs(a)`, `Math.floor(a)`, `Math.ceil(a)`, `Math.round(a)` | `a.abs()`, `a.floor()`, `a.ceil()`, `a.round()` | `round` rounds halves away from zero |
| `Math.max(a, b)`, `Math.min(a, b)` | `a.max(b)`, `a.min(b)` | |
| `parseInt(s)`, `parseFloat(s)`, `String(a)` | `s.toInteger()`, `s.toReal()`, `('' + a)` | Conversions |

Results are converted to the data type of the attribute they are assigned to or compared
with, as Henshin converts the results of its scripts: reals assigned to integer attributes
are truncated, and any value becomes text for a string attribute.

Not supported: assignments, increments, bitwise operators, `new`, functions, arrays,
objects, template literals, `typeof`, property access other than `length`, and calls of
Java classes, including Henshin's aggregation helpers and Java imports.
