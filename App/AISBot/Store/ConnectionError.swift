import Foundation

/// Fehler beim Verbinden einer App (Text zum direkten Anzeigen).
struct ConnectionError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}
