#if os(iOS)
import CoreLocation
import Foundation
import MapKit
import UserNotifications

/// Standort für die Scoops (`apple.location.*`, API v1.18).
///
/// - `current`: einmalige Ortung (`requestLocation`) plus Adresse per Reverse-Geocoding (MapKit).
/// - Orte (Geofences) mit `CLMonitor`: Beim Betreten/Verlassen gibt es eine lokale Mitteilung, und das Ereignis
///   geht an den Server (der Scoop bekommt es als Nachricht). Im Hintergrund braucht das „Immer“; iOS startet die App
///   dafür bei Bedarf neu (`resumeMonitoring` beim Start).
/// Koordinaten bleiben auf dem iPhone (UserDefaults `scoopPlaces`), der Server kennt nur Name, Notiz und Auslöser.
/// Standortdaten werden nie protokolliert.
@MainActor
final class LocationBridge: NSObject, CLLocationManagerDelegate {
    static let shared = LocationBridge()

    private let manager = CLLocationManager()
    private var authWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private let placesKey = "scoopPlaces"
    /// CLMonitor-Namen dürfen nur Buchstaben und Ziffern enthalten (sonst Absturz „Monitor name is not valid“).
    static let monitorName = "AISScoopsOrte"
    private var monitorCreation: Task<CLMonitor, Never>?
    /// Solange Orte überwacht werden: Sitzung mit „Immer“, damit iOS Ereignisse auch im Hintergrund zustellt.
    private var serviceSession: CLServiceSession?
    /// Ort ausgelöst (id, enter|exit, Zeitpunkt) → AppleDeviceAgent meldet es dem Server
    var onPlaceEvent: ((String, String, Date) -> Void)?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// always | when_in_use | denied | restricted | not_determined
    var permission: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "when_in_use"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
    }

    func requestWhenInUse() async -> String {
        guard manager.authorizationStatus == .notDetermined else { return permission }
        manager.requestWhenInUseAuthorization()
        await waitForAuthorization()
        return permission
    }

    /// „Immer“: iOS zeigt die Abfrage nur einmal; danach geht es nur über die Einstellungen.
    func requestAlways() async -> String {
        if manager.authorizationStatus == .notDetermined { _ = await requestWhenInUse() }
        guard manager.authorizationStatus == .authorizedWhenInUse else { return permission }
        manager.requestAlwaysAuthorization()
        await waitForAuthorization(timeout: 20)
        return permission
    }

    private func waitForAuthorization(timeout: Double = 60) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            authWaiters.append(c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resumeAuthWaiters()
            }
        }
    }

    private func resumeAuthWaiters() {
        let w = authWaiters
        authWaiters = []
        w.forEach { $0.resume() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // Die erste Meldung kommt sofort beim Anlegen des Managers (noch ohne Antwort des Nutzers)
            if status != .notDetermined { self.resumeAuthWaiters() }
            if status == .authorizedAlways { self.resumeMonitoring() }
            self.onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resumeLocationWaiters(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resumeLocationWaiters(nil) }
    }

    private func resumeLocationWaiters(_ location: CLLocation?) {
        let w = locationWaiters
        locationWaiters = []
        w.forEach { $0.resume(returning: location) }
    }

    private func locate(timeout: Double = 15) async -> CLLocation? {
        if let l = manager.location, Date().timeIntervalSince(l.timestamp) < 20, l.horizontalAccuracy <= 100 { return l }
        return await withCheckedContinuation { (c: CheckedContinuation<CLLocation?, Never>) in
            locationWaiters.append(c)
            if locationWaiters.count == 1 { manager.requestLocation() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resumeLocationWaiters(self?.manager.location)
            }
        }
    }

    // MARK: Befehle

    func run(_ command: String, _ p: JSONValue) async throws -> JSONValue {
        guard ["always", "when_in_use"].contains(permission) else {
            throw AppleBridgeError("AIS Scoops darf den Standort dieses iPhones nicht nutzen. In AIS Scoops unter Apps verbinden → Apple → Standort erlauben.")
        }
        switch command {
        case "apple.location.current": return try await current()
        case "apple.location.geofence_add": return try await addPlace(p)
        case "apple.location.geofences": return await places()
        case "apple.location.geofence_delete": return await deletePlace(p["id"]?.string ?? "")
        default: throw AppleBridgeError("Unbekannter Befehl \(command)")
        }
    }

    private func current() async throws -> JSONValue {
        guard let loc = await locate() else { throw AppleBridgeError("Standort gerade nicht verfügbar (kein GPS/WLAN-Signal?).") }
        var o: [String: JSONValue] = [
            "latitude": .number((loc.coordinate.latitude * 1e5).rounded() / 1e5),
            "longitude": .number((loc.coordinate.longitude * 1e5).rounded() / 1e5),
            "accuracy_m": .number(loc.horizontalAccuracy.rounded()),
            "timestamp": .string(AlarmBridge.iso(loc.timestamp)),
        ]
        if let item = await Self.reverseGeocode(loc) {
            o["address"] = .text(item.address?.fullAddress)
            o["place"] = .text(item.name)
        }
        return CmdResult.ok(o)
    }

    private func addPlace(_ p: JSONValue) async throws -> JSONValue {
        guard permission == "always" else {
            throw AppleBridgeError("Für Orte braucht AIS Scoops den Standortzugriff „Immer“.")
        }
        let id = p["id"]?.string ?? UUID().uuidString
        let name = p["name"]?.string ?? "Ort"
        let radius = Double(max(100, min(2000, p["radius"]?.int ?? 150)))
        var center: CLLocationCoordinate2D
        var address: String?
        if let text = p["address"]?.string, !text.isEmpty {
            guard let item = await Self.geocode(text) else { throw AppleBridgeError("Adresse nicht gefunden: \(text)") }
            center = item.location.coordinate
            address = item.address?.fullAddress ?? text
        } else {
            guard let loc = await locate() else { throw AppleBridgeError("Aktueller Standort nicht verfügbar.") }
            center = loc.coordinate
            address = await Self.reverseGeocode(loc)?.address?.fullAddress
        }
        var all = loadPlaces()
        guard all.count < 19 || all[id] != nil else { throw AppleBridgeError("Höchstens 19 Orte gleichzeitig (iOS-Grenze).") }
        let monitor = await ensureMonitor()
        await monitor.add(CLMonitor.CircularGeographicCondition(center: center, radius: radius), identifier: id,
                          assuming: .unsatisfied)
        all[id] = ["id": .string(id), "name": .string(name), "radius": .number(radius), "address": .text(address),
                   "latitude": .number(center.latitude), "longitude": .number(center.longitude),
                   "on_entry": .bool(p["on_entry"]?.bool ?? true), "on_exit": .bool(p["on_exit"]?.bool ?? false),
                   "created_at": .string(AlarmBridge.iso(Date()))]
        savePlaces(all)
        return CmdResult.ok(["geofence": .object(publicPlace(all[id] ?? [:]))])
    }

    private func places() async -> JSONValue {
        let all = loadPlaces()
        var out: [JSONValue] = []
        let monitor = await ensureMonitor()
        for (id, place) in all.sorted(by: { ($0.value["name"]?.string ?? "") < ($1.value["name"]?.string ?? "") }) {
            var o = publicPlace(place)
            if let state = await monitor.record(for: id)?.lastEvent.state {
                o["inside"] = state == .satisfied ? true : (state == .unsatisfied ? false : .null)
                // iOS überwacht den Ort gerade nicht (z. B. fehlende Berechtigung, Speicherfehler): offen sagen
                if state == .unmonitored { o["monitored"] = false }
            }
            out.append(.object(o))
        }
        return CmdResult.ok(["geofences": .array(out)])
    }

    private func deletePlace(_ id: String) async -> JSONValue {
        var all = loadPlaces()
        let removed = all.removeValue(forKey: id)
        savePlaces(all)
        await ensureMonitor().remove(id)
        return CmdResult.ok(["deleted": .object(["id": .string(id), "name": removed?["name"] ?? .null])])
    }

    /// Für den Scoop: Name, Adresse, Radius, Auslöser – ohne genaue Koordinaten.
    private func publicPlace(_ p: [String: JSONValue]) -> [String: JSONValue] {
        p.filter { !["latitude", "longitude"].contains($0.key) }
    }

    // MARK: Überwachung

    /// Genau ein Monitor pro Namen: Gleichzeitige Aufrufe warten auf dieselbe Anlage.
    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        if let monitorCreation { return await monitorCreation.value }
        let task = Task { @MainActor in await CLMonitor(Self.monitorName) }
        monitorCreation = task
        let m = await task.value
        if monitor == nil {
            monitor = m
            startEventLoop(m)
        }
        if serviceSession == nil { serviceSession = CLServiceSession(authorization: .always) }
        return monitor ?? m
    }

    /// Beim Start (auch wenn iOS die App wegen eines Orts im Hintergrund startet): Ereignisse wieder abholen.
    func resumeMonitoring() {
        guard monitor == nil, !loadPlaces().isEmpty else { return }
        Task { _ = await ensureMonitor() }
    }

    private func startEventLoop(_ m: CLMonitor) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            do {
                for try await event in await m.events {
                    guard let self else { return }
                    self.handle(id: event.identifier, state: event.state, date: event.date)
                }
            } catch {
                #if DEBUG
                print("[Orte] Überwachung beendet: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func handle(id: String, state: CLMonitor.Event.State, date: Date) {
        #if DEBUG
        print("[Orte] Ereignis \(id): \(state)")  // nur Zustand, keine Koordinaten
        #endif
        guard let place = loadPlaces()[id], state == .satisfied || state == .unsatisfied else { return }
        // Direkt nach dem Anlegen meldet iOS den Ausgangszustand – das ist kein Betreten/Verlassen
        if let created = place["created_at"]?.string.flatMap(ISO8601Parser.parse), date.timeIntervalSince(created) < 20 { return }
        let kind = state == .satisfied ? "enter" : "exit"
        let wanted = kind == "enter" ? (place["on_entry"]?.bool ?? true) : (place["on_exit"]?.bool ?? false)
        guard wanted else { return }
        let name = place["name"]?.string ?? "Ort"
        let content = UNMutableNotificationContent()
        content.title = kind == "enter" ? "\(name) betreten" : "\(name) verlassen"
        content.body = "Dein Scoop kümmert sich darum."
        content.sound = .default
        content.threadIdentifier = "ais-scoops-orte"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ort-\(id)-\(Int(date.timeIntervalSince1970))",
                                                                     content: content, trigger: nil))
        onPlaceEvent?(id, kind, date)
    }

    private func loadPlaces() -> [String: [String: JSONValue]] {
        guard let data = UserDefaults.standard.data(forKey: placesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: JSONValue]].self, from: data)) ?? [:]
    }

    private func savePlaces(_ places: [String: [String: JSONValue]]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(places), forKey: placesKey)
    }

    // MARK: Geocoding (MapKit, iOS 26)

    private static func reverseGeocode(_ location: CLLocation) async -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        return try? await request.mapItems.first
    }

    private static func geocode(_ text: String) async -> MKMapItem? {
        guard let request = MKGeocodingRequest(addressString: text) else { return nil }
        return try? await request.mapItems.first
    }
}
#endif
