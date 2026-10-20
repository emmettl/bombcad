import Testing

/// How long a test that waits on the app may run before it is taken as hung.
///
/// The app's runs share the GPU and the cores with every other suite and every other process on
/// the machine, so how long one takes says nothing about whether it is right: a run that takes a
/// second alone has taken minutes at load averages of 50–140. So the tests wait for the state they
/// are about (a run finished, a consumer caught up, a preview current), however long that takes,
/// with no deadline of their own; a state never reached, a fault, is a hang, which this limit
/// reports as a failure. Ten minutes: the slowest of them took 79 s at a load average of 141, and
/// CI's test step stops at 45. The app's own deadlines (a connection's steps, a probe, the end of
/// a run waiting for its companions) take nil in the tests, so that this is the only bound; and
/// no test may be given a shorter one (Scripts/check-test-deadlines.py).
extension Trait where Self == TimeLimitTrait {
    static var hangLimit: Self { .timeLimit(.minutes(10)) }
}
