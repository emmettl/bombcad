import Dispatch

/// Runs `body` for every index in `0..<iterations` across the CPU's cores, as
/// `DispatchQueue.concurrentPerform` does, returning once all have run.
///
/// Dispatch takes a `@Sendable` closure, which the parallel loops here cannot be: they write
/// through unsafe buffer pointers (often the `inout` parameter of `withUnsafeMutableBufferPointer`)
/// and read the solver's state and closures that the compiler cannot prove safe to share. They
/// are safe because every caller keeps to one rule, which the type system cannot check: each
/// iteration writes only what belongs to its own index (its plane, row, chunk or element), and
/// reads only what no iteration writes while the loop runs, or what is itself thread-safe (a
/// `Flag`). Checked at each call when this was introduced; a new caller must keep to it too.
func concurrently(iterations: Int, _ body: (Int) -> Void) {
    withoutActuallyEscaping(body) { body in
        let shared = UncheckedSendable(value: body)
        DispatchQueue.concurrentPerform(iterations: iterations) { shared.value($0) }
    }
}

/// A value handed to `concurrently(iterations:_:)`'s workers, safe by the rule it states.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
