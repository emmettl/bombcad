import SwiftUI

// Bindings into scene state that a menu choice can take away while a control showing it is still
// on screen: switching a gas cloud's source back to a charge removes the cloud, and SwiftUI reads
// the cloud's pickers' bindings once more before their section goes. A force-unwrap there crashed
// the app (16 October 2026); these read the value the control was made with instead, and write
// nothing, until the view is gone.
extension Binding {
    /// `path` of the value held in the optional state `root`, or `fallback` once it is nil.
    @MainActor
    static func into<Root>(_ root: Binding<Root?>, _ path: WritableKeyPath<Root, Value>, fallback: Value)
        -> Binding<Value>
    {
        Binding(
            get: { root.wrappedValue?[keyPath: path] ?? fallback },
            set: { value in
                guard var held = root.wrappedValue else { return }
                held[keyPath: path] = value
                root.wrappedValue = held
            })
    }

    /// `path` of element `index` of the optional array `root`, or `fallback` once there is no such
    /// element (the last one removed).
    @MainActor
    static func element<Element>(
        _ root: Binding<[Element]?>, at index: Int, _ path: WritableKeyPath<Element, Value>, fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let array = root.wrappedValue, array.indices.contains(index) else { return fallback }
                return array[index][keyPath: path]
            },
            set: { value in
                guard var array = root.wrappedValue, array.indices.contains(index) else { return }
                array[index][keyPath: path] = value
                root.wrappedValue = array
            })
    }
}
