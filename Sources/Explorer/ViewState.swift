import SwiftUI

/// SwiftUI's State, by another name. The Command Line Tools' SDK declares `@State` as a macro whose plugin ships only with
/// Xcode, so `@State` doesn't build without Xcode; the property wrapper under it, reached by this name, does.
typealias ViewState<Value> = State<Value>
