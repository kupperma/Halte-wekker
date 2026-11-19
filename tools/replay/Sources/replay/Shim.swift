// What the app's matcher files need from files the replay doesn't compile (Net.swift needs Apple's Network framework).

/// The request lanes `FieldFormat.net` names (Net.swift has the real one).
enum Lane: String, Sendable { case interactive, background }
