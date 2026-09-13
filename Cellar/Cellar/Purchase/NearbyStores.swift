import Foundation
import MapKit
import CoreLocation

/// A physical wine store near the user, from a local map search.
struct NearbyStore: Identifiable {
    let id = UUID()
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
    var phone: String?
    var distanceMeters: CLLocationDistance?

    var mapItem: MKMapItem {
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }
}

/// Finds wine stores near a coordinate with `MKLocalSearch`. No API key, no
/// cost — this is the "where to buy + directions" feature that works day one.
/// (Per-store inventory/price for a specific bottle needs a merchant API and
/// belongs behind `PurchaseService`; this answers "where are the wine shops".)
enum NearbyStores {
    static func search(near center: CLLocationCoordinate2D,
                       radiusMeters: CLLocationDistance = 8000) async -> [NearbyStore] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "wine store"
        request.region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: radiusMeters,
                                            longitudinalMeters: radiusMeters)
        if #available(iOS 13.0, *) {
            request.resultTypes = [.pointOfInterest]
        }

        let search = MKLocalSearch(request: request)
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        do {
            let response = try await search.start()
            return response.mapItems.compactMap { item in
                let coord = item.placemark.coordinate
                let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                return NearbyStore(
                    name: item.name ?? "Wine store",
                    address: Self.formatAddress(item.placemark),
                    coordinate: coord,
                    phone: item.phoneNumber,
                    distanceMeters: origin.distance(from: loc))
            }
            .sorted { ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude) }
        } catch {
            return []
        }
    }

    static func formatAddress(_ placemark: MKPlacemark) -> String {
        [placemark.subThoroughfare, placemark.thoroughfare,
         placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Opens Apple Maps with driving directions to the store.
    static func openDirections(to store: NearbyStore) {
        store.mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

/// One-shot location fetch for the nearby-store search. Keeps a strong ref to
/// itself until the fix arrives (CLLocationManager won't retain its delegate).
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var selfRef: OneShotLocation?

    func current() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            self.selfRef = self
            manager.delegate = self
            let status = manager.authorizationStatus
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                finish(nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ coord: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coord)
        continuation = nil
        selfRef = nil
    }
}
