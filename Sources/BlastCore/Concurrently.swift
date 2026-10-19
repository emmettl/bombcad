import Foundation

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
///
/// An `SDOFResponseMemo` the caller is remembering with goes with the work to each worker.
func concurrently(iterations: Int, _ body: (Int) -> Void) {
    let memo = UncheckedSendable(value: SDOFResponseMemo.active)
    withoutActuallyEscaping(body) { body in
        let shared = UncheckedSendable(value: body)
        DispatchQueue.concurrentPerform(iterations: iterations) { n in
            guard let remembering = memo.value else { return shared.value(n) }
            let before = SDOFResponseMemo.active
            SDOFResponseMemo.active = remembering
            shared.value(n)
            SDOFResponseMemo.active = before
        }
    }
}

/// A value handed to `concurrently(iterations:_:)`'s workers, safe by the rule it states.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
