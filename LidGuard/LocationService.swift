//
//  LocationService.swift
//  LidGuard
//
//  Fetches precise GPS location via CoreLocation with ipinfo.io fallback.
//  Adds locationType field ("GPS" or "IP") to LocationInfo.
//

import Foundation
import CoreLocation

// MARK: - LocationInfo Model

struct LocationInfo: Codable, Sendable {
    let ip: String
    let city: String
    let region: String
    let country: String
    let loc: String           // "lat,lon"
    let org: String           // ISP / organization
    let timezone: String
    let locationType: String  // "GPS" or "IP"

    /// Google Maps link for the coordinates.
    var mapsURL: String {
        "https://maps.google.com/?q=\(loc)"
    }

    /// Human-readable single-line summary.
    var summary: String {
        "[\(locationType)] \(city), \(region), \(country) (\(ip)) — \(org)"
    }

    /// Fallback when network is unavailable.
    static let unknown = LocationInfo(
        ip: "Unknown", city: "Unknown", region: "Unknown",
        country: "Unknown", loc: "0.0,0.0", org: "Unknown",
        timezone: "Unknown", locationType: "Unknown"
    )

    // CodingKeys so ipinfo.io JSON (which lacks locationType) still decodes
    enum CodingKeys: String, CodingKey {
        case ip, city, region, country, loc, org, timezone, locationType
    }

    init(ip: String, city: String, region: String, country: String,
         loc: String, org: String, timezone: String, locationType: String = "IP") {
        self.ip = ip; self.city = city; self.region = region
        self.country = country; self.loc = loc; self.org = org
        self.timezone = timezone; self.locationType = locationType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? "Unknown"
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? "Unknown"
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "Unknown"
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? "Unknown"
        loc = try c.decodeIfPresent(String.self, forKey: .loc) ?? "0.0,0.0"
        org = try c.decodeIfPresent(String.self, forKey: .org) ?? "Unknown"
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? "Unknown"
        locationType = try c.decodeIfPresent(String.self, forKey: .locationType) ?? "IP"
    }
}

// MARK: - LocationService

final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {

    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var waiting = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let status = self.manager.authorizationStatus
            print("[LocationService] Init — CLAuth status: \(status.rawValue) (3=authorized, 4=denied, 0=notDetermined)")
            print("[LocationService] Location services enabled: \(CLLocationManager.locationServicesEnabled())")
            if status == .notDetermined {
                self.manager.requestAlwaysAuthorization()
            }
            // Always start updating to warm the cache
            self.manager.startUpdatingLocation()
        }
    }

    // MARK: - Public API

    func fetchLocation() async -> LocationInfo {
        // Try GPS first
        let gpsLocation = await getGPS()

        // Always fetch IP info for public IP/ISP
        let ipInfo = await fetchIPInfo()

        if let gps = gpsLocation {
            let lat = String(format: "%.6f", gps.coordinate.latitude)
            let lon = String(format: "%.6f", gps.coordinate.longitude)
            let place = await reverseGeocode(location: gps)

            print("[LocationService] ✅ Using GPS location: \(lat),\(lon)")
            return LocationInfo(
                ip: ipInfo?.ip ?? "Unknown",
                city: place.city.isEmpty ? (ipInfo?.city ?? "Unknown") : place.city,
                region: place.region.isEmpty ? (ipInfo?.region ?? "Unknown") : place.region,
                country: place.country.isEmpty ? (ipInfo?.country ?? "Unknown") : place.country,
                loc: "\(lat),\(lon)",
                org: ipInfo?.org ?? "Unknown",
                timezone: ipInfo?.timezone ?? TimeZone.current.identifier,
                locationType: "📡 GPS"
            )
        }

        if let ipInfo = ipInfo {
            print("[LocationService] ⚠️ GPS failed — using IP location.")
            return LocationInfo(
                ip: ipInfo.ip, city: ipInfo.city, region: ipInfo.region,
                country: ipInfo.country, loc: ipInfo.loc, org: ipInfo.org,
                timezone: ipInfo.timezone, locationType: "🌐 IP"
            )
        }

        return .unknown
    }

    // MARK: - GPS

    private func getGPS() async -> CLLocation? {
        // First try: check if manager already has a cached location
        let cached: CLLocation? = await MainActor.run {
            let loc = manager.location
            if let loc = loc {
                let age = Date().timeIntervalSince(loc.timestamp)
                print("[LocationService] Cached location age: \(String(format: "%.1f", age))s, coords: \(loc.coordinate.latitude),\(loc.coordinate.longitude)")
                if age < 60 { return loc }  // Use if less than 60 seconds old
            }
            return nil
        }

        if let cached = cached {
            print("[LocationService] 📍 Using cached GPS location")
            return cached
        }

        // Second try: request a fresh location
        print("[LocationService] Requesting fresh GPS fix...")
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    cont.resume(returning: nil)
                    return
                }

                let status = self.manager.authorizationStatus
                print("[LocationService] Auth status for GPS request: \(status.rawValue)")

                guard CLLocationManager.locationServicesEnabled(),
                      status == .authorized || status == .authorizedAlways else {
                    print("[LocationService] ❌ GPS not available — services enabled: \(CLLocationManager.locationServicesEnabled()), auth: \(status.rawValue)")
                    cont.resume(returning: nil)
                    return
                }

                self.waiting = true
                self.continuation = cont

                self.manager.startUpdatingLocation()
                self.manager.requestLocation()

                // Timeout after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self = self, self.waiting else { return }
                    self.waiting = false
                    let c = self.continuation
                    self.continuation = nil
                    print("[LocationService] ⏰ GPS request timed out after 10s")
                    // Last resort: try manager.location even if old
                    c?.resume(returning: self.manager.location)
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        print("[LocationService] 📍 didUpdateLocations: \(loc.coordinate.latitude),\(loc.coordinate.longitude) ±\(String(format: "%.0f", loc.horizontalAccuracy))m")

        if waiting, let cont = continuation {
            waiting = false
            continuation = nil
            cont.resume(returning: loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationService] ❌ didFailWithError: \(error.localizedDescription)")

        if waiting, let cont = continuation {
            waiting = false
            continuation = nil
            cont.resume(returning: nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("[LocationService] 🔄 Auth changed to: \(status.rawValue)")
        if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    // MARK: - Reverse Geocoding

    private func reverseGeocode(location: CLLocation) async -> (city: String, region: String, country: String) {
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(location)
            if let p = marks.first {
                return (p.locality ?? p.subAdministrativeArea ?? "",
                        p.administrativeArea ?? "",
                        p.country ?? "")
            }
        } catch {
            print("[LocationService] Geocode error: \(error.localizedDescription)")
        }
        return ("", "", "")
    }

    // MARK: - IP Fallback

    private func fetchIPInfo() async -> LocationInfo? {
        guard let url = URL(string: "https://ipinfo.io/json") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        do {
            let (data, resp) = try await URLSession(configuration: config).data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LocationInfo.self, from: data)
        } catch { return nil }
    }
}
