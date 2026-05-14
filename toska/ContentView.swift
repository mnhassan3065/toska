import SwiftUI
import MapKit
import CoreLocation
import Combine
import AVFoundation

// MARK: - Voice Engine (Siri-style smooth female)
@MainActor
class ToskaVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    @Published var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
        setupAudio()
    }

    private func setupAudio() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt,
            options: [.duckOthers, .allowBluetoothA2DP]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func say(_ text: String, priority: Bool = false) {
        if priority { synth.stopSpeaking(at: .immediate) }
        else if synth.isSpeaking { return }

        let u = AVSpeechUtterance(string: text)

        // Find best smooth female English voice
        let preferred = ["com.apple.voice.enhanced.en-GB.Serena",
                         "com.apple.ttsbundle.siri_female_en-GB_compact",
                         "com.apple.voice.enhanced.en-US.Samantha",
                         "com.apple.ttsbundle.Samantha-compact"]

        var chosenVoice: AVSpeechSynthesisVoice? = nil
        for id in preferred {
            if let v = AVSpeechSynthesisVoice(identifier: id) {
                chosenVoice = v; break
            }
        }
        // Fallback: any female GB voice
        if chosenVoice == nil {
            chosenVoice = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en-GB") && $0.gender == .female }
                .first
        }
        // Final fallback: any GB voice
        if chosenVoice == nil {
            chosenVoice = AVSpeechSynthesisVoice(language: "en-GB")
        }

        u.voice          = chosenVoice
        u.rate           = 0.50
        u.pitchMultiplier = 1.1
        u.volume         = 1.0
        u.preUtteranceDelay  = 0.1
        u.postUtteranceDelay = 0.1
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .word) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}

// MARK: - Speed Camera Model
struct SpeedCamera: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let speedLimit: Int
    let type: CamType
    enum CamType: String { case fixed = "Fixed", mobile = "Mobile", redLight = "Red Light", average = "Average Speed" }
    var icon: String {
        switch type {
        case .fixed:    return "camera.fill"
        case .mobile:   return "car.fill"
        case .redLight: return "light.beacon.max.fill"
        case .average:  return "ruler.fill"
        }
    }
    var color: UIColor {
        switch type {
        case .fixed, .average: return .systemOrange
        case .mobile:          return .systemYellow
        case .redLight:        return .systemRed
        }
    }
}

// MARK: - Nearby Place Model
struct NearbyPlace: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let address: String
    let type: PlaceType
    let distance: Double
    enum PlaceType { case fuel, parking }
    var icon: String { type == .fuel ? "fuelpump.fill" : "parkingsign.circle.fill" }
}


// MARK: - Saved Places
struct SavedPlace: Codable, Identifiable {
    let id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var isHome: Bool
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    init(id: UUID = UUID(), name: String, address: String, coordinate: CLLocationCoordinate2D, isHome: Bool = false) {
        self.id        = id
        self.name      = name
        self.address   = address
        self.latitude  = coordinate.latitude
        self.longitude = coordinate.longitude
        self.isHome    = isHome
    }
}

class PlacesStore: ObservableObject {
    @Published var home: SavedPlace?       = nil
    @Published var favourites: [SavedPlace] = []
    
    private let homeKey = "toska_home"
    private let favsKey = "toska_favourites"
    
    init() { load() }
    
    func setHome(_ place: SavedPlace) {
        var p     = place
        p.isHome  = true
        home      = p
        save()
    }
    
    func addFavourite(_ place: SavedPlace) {
        guard !favourites.contains(where: { $0.name == place.name }) else { return }
        favourites.append(place)
        save()
    }
    
    func removeFavourite(at offsets: IndexSet) {
        favourites.remove(atOffsets: offsets)
        save()
    }
    
    func removeHome() { home = nil; save() }
    
    private func save() {
        if let h = home, let data = try? JSONEncoder().encode(h) {
            UserDefaults.standard.set(data, forKey: homeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: homeKey)
        }
        if let data = try? JSONEncoder().encode(favourites) {
            UserDefaults.standard.set(data, forKey: favsKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: homeKey),
           let h = try? JSONDecoder().decode(SavedPlace.self, from: data) {
            home = h
        }
        if let data = UserDefaults.standard.data(forKey: favsKey),
           let f = try? JSONDecoder().decode([SavedPlace].self, from: data) {
            favourites = f
        }
    }
}

// MARK: - Location Manager
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private var isFirstFix = true

    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published var heading: CLLocationDirection = 0
    @Published var speed: Double = 0  // km/h
    @Published var accuracy: Double = 0
    @Published var gpsOK = false
    @Published var gpsText = "Searching..."
    @Published var denied = false
    @Published var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),
        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
    )

    override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        mgr.distanceFilter  = 3
        mgr.headingFilter   = 3
        mgr.requestWhenInUseAuthorization()
    }

    func beginNavigation() {
        mgr.startUpdatingLocation()
        mgr.startUpdatingHeading()
        mgr.activityType = .automotiveNavigation
        mgr.pausesLocationUpdatesAutomatically = false
    }

    func endNavigation() {
        mgr.activityType   = .other
        mgr.stopUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        DispatchQueue.main.async {
            switch m.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.denied   = false
                self.gpsText  = "GPS"
                m.startUpdatingLocation()
                m.startUpdatingHeading()
            case .denied, .restricted:
                self.denied   = true
                self.gpsOK    = false
                self.gpsText  = "Denied"
            default:
                m.requestWhenInUseAuthorization()
            }
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last,
              loc.horizontalAccuracy > 0,
              loc.horizontalAccuracy < 65 else { return }
        DispatchQueue.main.async {
            self.coordinate = loc.coordinate
            self.speed      = max(0, loc.speed * 3.6)
            self.accuracy   = loc.horizontalAccuracy
            self.gpsOK      = true
            self.gpsText    = "GPS ✓"
            if self.isFirstFix {
                self.isFirstFix      = false
                self.mapRegion.center = loc.coordinate
            }
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard h.headingAccuracy >= 0 else { return }
        DispatchQueue.main.async { self.heading = h.trueHeading }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        DispatchQueue.main.async {
            self.gpsOK   = false
            self.gpsText = "No Signal"
        }
    }
}

// MARK: - Navigation Manager
class NavigationManager: ObservableObject {
    @Published var polyline: MKPolyline?    = nil
    @Published var steps: [MKRoute.Step]    = []
    @Published var stepIndex                = 0
    @Published var totalTime: String        = ""
    @Published var totalDist: String        = ""
    @Published var etaTime: String          = ""
    @Published var remainingTime: String    = ""
    @Published var remainingDist: String    = ""
    @Published var distToNext: String       = ""
    @Published var currentInstruction: String = ""
    @Published var nextInstruction: String  = ""
    @Published var isCalculating            = false
    @Published var hasRoute                 = false
    @Published var isNavigating             = false
    @Published var hasArrived               = false
    @Published var errorMsg: String         = ""
    @Published var showError                = false

    // Speed cameras
    @Published var nearestCamera: SpeedCamera?   = nil
    @Published var cameraDistance: Double        = 999
    @Published var cameraAlertActive             = false

    // Nearby places
    @Published var nearbyFuel: [NearbyPlace]     = []
    @Published var nearbyParking: [NearbyPlace]  = []
    @Published var isLoadingPlaces               = false

    private let voice       = ToskaVoice()
    private var spokenAt    = Set<Int>()
    private var routeDistance: Double = 0
    private var routeTime: Double     = 0
    private var startTime: Date?      = nil
    private var cameraAlertCooldown   = false

    let cameras: [SpeedCamera] = [
        // A1 - North London
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.6198,longitude:-0.1219), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.6076,longitude:-0.1198), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5942,longitude:-0.1174), speedLimit:40, type:.fixed),
        // A2 - Old Kent Road / New Cross
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4785,longitude:-0.0517), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4732,longitude:-0.0443), speedLimit:30, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4712,longitude:-0.0392), speedLimit:30, type:.fixed),
        // A3 - Clapham / Tooting
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4641,longitude:-0.1612), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4447,longitude:-0.1948), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4284,longitude:-0.2181), speedLimit:40, type:.average),
        // A4 - Great West Road / Chiswick
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4914,longitude:-0.2279), speedLimit:40, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4891,longitude:-0.2567), speedLimit:40, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4876,longitude:-0.2979), speedLimit:40, type:.fixed),
        // A10 - Tottenham / Stoke Newington
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5614,longitude:-0.0732), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5733,longitude:-0.0716), speedLimit:30, type:.fixed),
        // A20 - Lee / Lewisham
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4532,longitude:-0.0176), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4499,longitude:0.0089), speedLimit:30, type:.fixed),
        // A21 - Bromley
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4082,longitude:0.0148), speedLimit:40, type:.fixed),
        // A23 - Brixton / Streatham
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4614,longitude:-0.1153), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4386,longitude:-0.1241), speedLimit:30, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4181,longitude:-0.1298), speedLimit:30, type:.fixed),
        // A40 - Western Avenue
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5219,longitude:-0.2451), speedLimit:40, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5213,longitude:-0.2762), speedLimit:50, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5249,longitude:-0.3098), speedLimit:50, type:.fixed),
        // A41 - Finchley Road
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5672,longitude:-0.1876), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5821,longitude:-0.1947), speedLimit:30, type:.fixed),
        // A406 - North Circular
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5716,longitude:-0.2234), speedLimit:40, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5698,longitude:-0.1432), speedLimit:40, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5591,longitude:-0.0514), speedLimit:40, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5462,longitude:0.0287), speedLimit:40, type:.fixed),
        // A316 - Richmond / Twickenham
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4598,longitude:-0.2912), speedLimit:40, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4512,longitude:-0.3187), speedLimit:40, type:.fixed),
        // M25 / M4 / M1 approaches
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5124,longitude:-0.4512), speedLimit:50, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5634,longitude:-0.4123), speedLimit:70, type:.average),
        // Central London - congestion zone
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5147,longitude:-0.1348), speedLimit:20, type:.redLight),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5089,longitude:-0.1267), speedLimit:20, type:.redLight),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5021,longitude:-0.1147), speedLimit:20, type:.redLight),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5198,longitude:-0.0876), speedLimit:20, type:.redLight),
        // Blackwall Tunnel approach
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5012,longitude:0.0089), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4987,longitude:0.0143), speedLimit:30, type:.average),
        // Rotherhithe Tunnel
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4987,longitude:-0.0521), speedLimit:20, type:.fixed),
        // East London - A13
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5123,longitude:0.0478), speedLimit:40, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5134,longitude:0.0812), speedLimit:40, type:.average),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.5156,longitude:0.1198), speedLimit:50, type:.fixed),
        // Hammersmith / Fulham
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4912,longitude:-0.2234), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4823,longitude:-0.2012), speedLimit:30, type:.redLight),
        // Wandsworth / Putney Bridge
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4587,longitude:-0.2098), speedLimit:30, type:.fixed),
        SpeedCamera(coordinate: CLLocationCoordinate2D(latitude:51.4632,longitude:-0.2187), speedLimit:30, type:.redLight),
    ]

    // MARK: Route Calculation
    func calculateRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, destName: String) {
        isCalculating = true
        reset(keepDest: true)

        let req             = MKDirections.Request()
        req.source          = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination     = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType   = .automobile
        req.requestsAlternateRoutes = false

        MKDirections(request: req).calculate { [weak self] res, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCalculating = false

                guard let route = res?.routes.first else {
                    self.errorMsg  = err?.localizedDescription ?? "No route found."
                    self.showError = true
                    return
                }

                self.polyline       = route.polyline
                self.hasRoute       = true
                self.routeDistance  = route.distance
                self.routeTime      = route.expectedTravelTime
                self.steps          = route.steps.filter { !$0.instructions.isEmpty }
                self.totalTime      = self.fmtTime(route.expectedTravelTime)
                self.totalDist      = self.fmtDist(route.distance)

                let eta             = Date().addingTimeInterval(route.expectedTravelTime)
                let f               = DateFormatter(); f.timeStyle = .short
                self.etaTime        = f.string(from: eta)

                self.currentInstruction = self.steps.first?.instructions ?? ""
                self.nextInstruction    = self.steps.dropFirst().first?.instructions ?? ""

                self.voice.say("Route found. \(self.totalDist), estimated \(self.totalTime). \(self.currentInstruction)")
            }
        }
    }

    // MARK: Start Navigation
    func startNavigation() {
        guard hasRoute else { return }
        isNavigating = true
        hasArrived   = false
        stepIndex    = 0
        spokenAt     = []
        startTime    = Date()
        voice.say(steps.first?.instructions ?? "Follow the route", priority: true)
    }

    func stopNavigation() {
        isNavigating = false
        voice.stop()
    }

    // MARK: Live Update
    func updateProgress(userCoord: CLLocationCoordinate2D, speed: Double) {
        updateCameras(userCoord: userCoord, speed: speed)
        guard isNavigating, stepIndex < steps.count else { return }

        let step      = steps[stepIndex]
        let stepPoint = step.polyline.coordinate
        let stepLoc   = CLLocation(latitude: stepPoint.latitude, longitude: stepPoint.longitude)
        let userLoc   = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        let dist      = userLoc.distance(from: stepLoc)

        // Update distance to next
        distToNext = dist < 1000
            ? "\(Int(dist)) m"
            : String(format: "%.1f km", dist/1000)

        // Update remaining
        if let start = startTime {
            let elapsed         = Date().timeIntervalSince(start)
            let remaining       = max(0, routeTime - elapsed)
            remainingTime       = fmtTime(remaining)
        }

        // Voice at 300m, 100m
        if dist < 300 && !spokenAt.contains(stepIndex * 10 + 3) {
            spokenAt.insert(stepIndex * 10 + 3)
            let d = dist < 1000 ? "in \(Int(dist)) metres" : "in \(String(format:"%.1f",dist/1000)) kilometres"
            voice.say("\(d), \(step.instructions)")
        }
        if dist < 80 && !spokenAt.contains(stepIndex * 10 + 1) {
            spokenAt.insert(stepIndex * 10 + 1)
            voice.say(step.instructions, priority: true)
        }

        // Advance step
        if dist < 20 {
            stepIndex += 1
            if stepIndex < steps.count {
                currentInstruction  = steps[stepIndex].instructions
                nextInstruction     = stepIndex + 1 < steps.count
                    ? steps[stepIndex + 1].instructions
                    : "Arriving at destination"
            } else {
                currentInstruction  = "You have arrived!"
                nextInstruction     = ""
                hasArrived          = true
                isNavigating        = false
                voice.say("You have arrived at your destination. Have a wonderful time!", priority: true)
            }
        }
    }

    // MARK: Camera Check
    private func updateCameras(userCoord: CLLocationCoordinate2D, speed: Double) {
        let userLoc = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
        var nearest: SpeedCamera? = nil
        var nearestDist: Double   = 600

        for cam in cameras {
            let camLoc = CLLocation(latitude: cam.coordinate.latitude, longitude: cam.coordinate.longitude)
            let d      = userLoc.distance(from: camLoc)
            if d < nearestDist { nearestDist = d; nearest = cam }
        }

        DispatchQueue.main.async {
            self.nearestCamera   = nearest
            self.cameraDistance  = nearestDist

            if let cam = nearest, nearestDist < 300, !self.cameraAlertCooldown {
                self.cameraAlertActive   = true
                self.cameraAlertCooldown = true
                let distStr = nearestDist < 100 ? "ahead" : "in \(Int(nearestDist)) metres"
                self.voice.say("Warning! \(cam.type.rawValue) camera \(distStr). Speed limit \(cam.speedLimit) miles per hour.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    self.cameraAlertCooldown = false
                }
            }
            if nearestDist > 350 { self.cameraAlertActive = false }
        }
    }

    // MARK: Nearby Search
    func searchNearby(coord: CLLocationCoordinate2D) {
        isLoadingPlaces = true
        nearbyFuel      = []
        nearbyParking   = []

        let region = MKCoordinateRegion(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500)
        let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        // Search fuel
        let fuelReq = MKLocalSearch.Request()
        fuelReq.naturalLanguageQuery = "petrol station"
        fuelReq.region = region
        MKLocalSearch(request: fuelReq).start { [weak self] res, _ in
            DispatchQueue.main.async {
                self?.nearbyFuel = res?.mapItems.prefix(5).map { item in
                    let c    = item.placemark.coordinate
                    let loc  = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let dist = userLoc.distance(from: loc)
                    return NearbyPlace(
                        name: item.name ?? "Petrol Station",
                        coordinate: c,
                        address: item.placemark.thoroughfare ?? "",
                        type: .fuel,
                        distance: dist
                    )
                } ?? []
            }
        }

        // Search parking
        let parkReq = MKLocalSearch.Request()
        parkReq.naturalLanguageQuery = "car park parking"
        parkReq.region = region
        MKLocalSearch(request: parkReq).start { [weak self] res, _ in
            DispatchQueue.main.async {
                self?.nearbyParking = res?.mapItems.prefix(5).map { item in
                    let c    = item.placemark.coordinate
                    let loc  = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    let dist = userLoc.distance(from: loc)
                    return NearbyPlace(
                        name: item.name ?? "Car Park",
                        coordinate: c,
                        address: item.placemark.thoroughfare ?? "",
                        type: .parking,
                        distance: dist
                    )
                } ?? []
                self?.isLoadingPlaces = false
            }
        }
    }

    func reset(keepDest: Bool = false) {
        polyline            = nil
        hasRoute            = false
        isNavigating        = false
        hasArrived          = false
        steps               = []
        stepIndex           = 0
        spokenAt            = []
        currentInstruction  = ""
        nextInstruction     = ""
        distToNext          = ""
        totalTime           = ""
        totalDist           = ""
        etaTime             = ""
        remainingTime       = ""
        nearestCamera       = nil
        cameraAlertActive   = false
        voice.stop()
        if !keepDest { nearbyFuel = []; nearbyParking = [] }
    }

    // MARK: Formatters
    func fmtTime(_ secs: Double) -> String {
        let m = Int(secs/60)
        return m < 60 ? "\(m) min" : "\(m/60)h \(m%60)m"
    }
    func fmtDist(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.1f km", m/1000)
    }
}

// MARK: - Map UIView
struct ToskaMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var polyline: MKPolyline?
    var destCoord: CLLocationCoordinate2D?
    var isNavigating: Bool
    var cameras: [SpeedCamera]
    var fuelPlaces: [NearbyPlace]
    var parkPlaces: [NearbyPlace]

    func makeUIView(context: Context) -> MKMapView {
        let m                   = MKMapView()
        m.delegate              = context.coordinator
        m.showsUserLocation     = true
        m.mapType               = .mutedStandard
        m.showsCompass          = true
        m.showsTraffic          = true
        m.showsScale            = true
        m.isRotateEnabled       = true
        m.isZoomEnabled         = true
        m.isPitchEnabled        = true
        m.userTrackingMode      = .follow
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        // Tracking mode
        let mode: MKUserTrackingMode = isNavigating ? .followWithHeading : .follow
        if m.userTrackingMode != mode { m.setUserTrackingMode(mode, animated: true) }

        // Route overlay
        let existing = m.overlays.compactMap { $0 as? MKPolyline }
        if let p = polyline, existing.isEmpty {
            m.addOverlay(p, level: .aboveRoads)
            if !isNavigating {
                m.setVisibleMapRect(p.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 140, left: 50, bottom: 380, right: 50),
                    animated: true)
            }
        } else if polyline == nil && !existing.isEmpty {
            m.removeOverlays(m.overlays)
        }

        // Annotations — only add once
        let currentIds = Set(m.annotations.compactMap { ($0 as? ToskaAnnotation)?.uniqueId })

        // Destination
        if let d = destCoord {
            let id = "dest_\(d.latitude)_\(d.longitude)"
            if !currentIds.contains(id) {
                let a = ToskaAnnotation(id: id, coord: d, kind: .destination, title: "Destination", subtitle: "")
                m.addAnnotation(a)
            }
        } else {
            m.annotations.filter { ($0 as? ToskaAnnotation)?.kind == .destination }.forEach { m.removeAnnotation($0) }
        }

        // Cameras
        for cam in cameras {
            let id = "cam_\(cam.id)"
            if !currentIds.contains(id) {
                let a = ToskaAnnotation(id: id, coord: cam.coordinate, kind: .camera,
                    title: "\(cam.type.rawValue) Camera", subtitle: "\(cam.speedLimit) mph")
                m.addAnnotation(a)
            }
        }

        // Fuel
        for p in fuelPlaces {
            let id = "fuel_\(p.id)"
            if !currentIds.contains(id) {
                let a = ToskaAnnotation(id: id, coord: p.coordinate, kind: .fuel,
                    title: p.name, subtitle: "\(Int(p.distance))m away")
                m.addAnnotation(a)
            }
        }

        // Parking
        for p in parkPlaces {
            let id = "park_\(p.id)"
            if !currentIds.contains(id) {
                let a = ToskaAnnotation(id: id, coord: p.coordinate, kind: .parking,
                    title: p.name, subtitle: "\(Int(p.distance))m away")
                m.addAnnotation(a)
            }
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    class Coord: NSObject, MKMapViewDelegate {
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            guard let p = o as? MKPolyline else { return MKOverlayRenderer() }
            let r           = MKPolylineRenderer(polyline: p)
            r.strokeColor   = UIColor(red:0.79, green:0.66, blue:0.30, alpha:1)
            r.lineWidth     = 7
            r.lineCap       = .round
            r.lineJoin      = .round
            return r
        }

        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            guard let ta = a as? ToskaAnnotation else { return nil }
            let v = MKMarkerAnnotationView(annotation: a, reuseIdentifier: ta.kind.rawValue)
            switch ta.kind {
            case .destination:
                v.markerTintColor = UIColor(red:0.79, green:0.66, blue:0.30, alpha:1)
                v.glyphImage      = UIImage(systemName: "flag.fill")
                v.animatesWhenAdded = true
            case .camera:
                v.markerTintColor = .systemOrange
                v.glyphImage      = UIImage(systemName: "camera.fill")
            case .fuel:
                v.markerTintColor = .systemGreen
                v.glyphImage      = UIImage(systemName: "fuelpump.fill")
            case .parking:
                v.markerTintColor = .systemBlue
                v.glyphImage      = UIImage(systemName: "parkingsign")
            }
            v.displayPriority   = .required
            v.canShowCallout    = true
            return v
        }
    }
}

// MARK: - Custom Annotation
class ToskaAnnotation: NSObject, MKAnnotation {
    enum Kind: String { case destination, camera, fuel, parking }
    let uniqueId: String
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    init(id: String, coord: CLLocationCoordinate2D, kind: Kind, title: String, subtitle: String) {
        self.uniqueId   = id
        self.kind       = kind
        self.coordinate = coord
        self.title      = title
        self.subtitle   = subtitle
    }
}

// MARK: - Colors
extension Color {
    static let g1 = Color(red:0.79, green:0.66, blue:0.30)
    static let g2 = Color(red:0.91, green:0.79, blue:0.42)
    static let b1 = Color(red:0.04, green:0.04, blue:0.05)
    static let b2 = Color(red:0.10, green:0.10, blue:0.12)
    static let b3 = Color(red:0.15, green:0.15, blue:0.18)
}

// MARK: - Turn Icon Helper
func turnIcon(for instruction: String) -> String {
    let i = instruction.lowercased()
    if i.contains("turn left")            { return "arrow.turn.up.left" }
    if i.contains("turn right")           { return "arrow.turn.up.right" }
    if i.contains("sharp left")           { return "arrow.turn.down.left" }
    if i.contains("sharp right")          { return "arrow.turn.down.right" }
    if i.contains("slight left")          { return "arrow.up.left" }
    if i.contains("slight right")         { return "arrow.up.right" }
    if i.contains("u-turn") || i.contains("uturn") { return "arrow.uturn.left" }
    if i.contains("roundabout")           { return "arrow.2.circlepath" }
    if i.contains("motorway") || i.contains("highway") { return "road.lanes" }
    if i.contains("exit")                 { return "arrow.up.right.circle" }
    if i.contains("arriv") || i.contains("destination") { return "flag.checkered" }
    if i.contains("merge")                { return "arrow.merge" }
    return "arrow.up"
}

// MARK: - Navigation Banner
struct NavBanner: View {
    let nm: NavigationManager
    let speed: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Turn icon
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors:[.g1,.g2], startPoint:.topLeading, endPoint:.bottomTrailing))
                        .frame(width: 60, height: 60)
                        .shadow(color:.g1.opacity(0.4), radius:8, y:3)
                    Image(systemName: turnIcon(for: nm.currentInstruction))
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.black)
                }

                VStack(alignment: .leading, spacing: 5) {
                    if !nm.distToNext.isEmpty {
                        Text(nm.distToNext)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.g2)
                    }
                    Text(nm.currentInstruction)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }

                Spacer()

                // Speedometer
                VStack(spacing: 2) {
                    Text("\(Int(speed))")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("km/h")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                }
                .frame(width: 52, height: 52)
                .background(speed > 80 ? Color.red.opacity(0.3) : Color.b3)
                .cornerRadius(12)
            }
            .padding(16)
            .background(Color.b2)

            if !nm.nextInstruction.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.g1.opacity(0.8))
                    Text("Then: \(nm.nextInstruction)")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    Spacer()
                    if !nm.remainingTime.isEmpty {
                        Text(nm.remainingTime)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.g1)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.b3)
            }
        }
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.g1.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}

// MARK: - Camera Alert
struct CameraAlert: View {
    let camera: SpeedCamera
    let distance: Double
    let speed: Double

    var isUrgent: Bool { distance < 100 }
    var userMph: Int { Int(speed / 1.609) }
    var isSpeeding: Bool { userMph > camera.speedLimit }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isUrgent ? Color.red : Color.orange)
                    .frame(width: 46, height: 46)
                Image(systemName: camera.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(isUrgent ? "⚠️ Camera Ahead!" : "Speed Camera")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isUrgent ? .red : .orange)
                HStack(spacing: 8) {
                    Text("\(Int(distance))m")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text("•")
                        .foregroundColor(.gray)
                    Text("\(camera.type.rawValue)")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    Text("• Limit: \(camera.speedLimit)mph")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            VStack(spacing: 2) {
                Text("\(userMph)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(isSpeeding ? .red : .green)
                Text("mph")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .frame(width: 48, height: 48)
            .background(isSpeeding ? Color.red.opacity(0.2) : Color.green.opacity(0.1))
            .cornerRadius(10)
        }
        .padding(14)
        .background(Color.b2)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(isUrgent ? Color.red.opacity(0.7) : Color.orange.opacity(0.5), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }
}

// MARK: - Route Stats Card
struct RouteCard: View {
    let nm: NavigationManager
    var body: some View {
        HStack {
            cell(nm.totalTime,  "DURATION")
            Divider().background(Color.g1.opacity(0.3))
            cell(nm.totalDist,  "DISTANCE")
            Divider().background(Color.g1.opacity(0.3))
            cell(nm.etaTime,    "ARRIVAL")
        }
        .frame(height: 68).padding(.horizontal, 14)
        .background(Color.b2).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.g1.opacity(0.2), lineWidth: 1))
    }
    func cell(_ v: String, _ l: String) -> some View {
        VStack(spacing: 3) {
            Text(v)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundColor(.g1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(l)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.gray)
                .tracking(0.8)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: - Nearby Places Sheet
struct NearbySheet: View {
    let nm: NavigationManager
    let onNavigate: (CLLocationCoordinate2D, String) -> Void
    @Binding var isShowing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Handle
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.2)).frame(width: 36, height: 4)
                Spacer()
            }.padding(.top, 12).padding(.bottom, 16)

            Text("Nearby")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                .padding(.horizontal, 20).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if nm.isLoadingPlaces {
                        HStack { Spacer(); ProgressView().tint(.g1); Spacer() }.padding(30)
                    } else {
                        // Fuel
                        if !nm.nearbyFuel.isEmpty {
                            sectionHeader("⛽ Petrol Stations", count: nm.nearbyFuel.count)
                            ForEach(nm.nearbyFuel) { p in placeRow(p, onNavigate: onNavigate, isShowing: $isShowing) }
                        }
                        // Parking
                        if !nm.nearbyParking.isEmpty {
                            sectionHeader("🅿️ Car Parks", count: nm.nearbyParking.count)
                            ForEach(nm.nearbyParking) { p in placeRow(p, onNavigate: onNavigate, isShowing: $isShowing) }
                        }
                        if nm.nearbyFuel.isEmpty && nm.nearbyParking.isEmpty {
                            Text("No results nearby. Try searching manually.")
                                .font(.system(size: 14)).foregroundColor(.gray)
                                .padding(20)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color.b1)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Spacer()
            Text("\(count) found")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }.padding(.top, 4)
    }

    func placeRow(_ p: NearbyPlace, onNavigate: @escaping (CLLocationCoordinate2D, String) -> Void, isShowing: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(p.type == .fuel ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: p.icon)
                    .font(.system(size: 16))
                    .foregroundColor(p.type == .fuel ? .green : .blue)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(p.address.isEmpty ? "\(Int(p.distance))m away" : p.address)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            Spacer()
            Button(action: {
                isShowing.wrappedValue = false
                onNavigate(p.coordinate, p.name)
            }) {
                Text("Go")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                    .cornerRadius(20)
            }
        }
        .padding(12)
        .background(Color.b2)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.g1.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Status Pill
struct Pill: View {
    let text: String; let on: Bool; var accent = false
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent ? Color.g1 : (on ? Color.green : Color.gray.opacity(0.4)))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(accent ? .g1 : .white.opacity(0.6))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.b2).clipShape(Capsule())
        .overlay(Capsule().stroke(accent ? Color.g1.opacity(0.4) : Color.g1.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Quick Chip
struct Chip: View {
    let e, t, q: String; let fn: ()->Void
    var body: some View {
        Button(action: fn) {
            HStack(spacing: 5) {
                Text(e).font(.system(size: 13))
                Text(t).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Color.b2).clipShape(Capsule())
            .overlay(Capsule().stroke(Color.g1.opacity(0.2), lineWidth: 1))
        }
    }
}

// MARK: - Arrived View
struct ArrivedView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.system(size: 48))
                .foregroundColor(.g1)
            Text("You have arrived!")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundColor(.white)
            Button(action: onDismiss) {
                Text("Done")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                    .cornerRadius(14)
            }
        }
        .padding(28)
        .background(Color.b2)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.g1.opacity(0.4), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.6), radius: 24)
        .padding(.horizontal, 32)
    }
}


// MARK: - Places Sheet (Home + Favourites)
struct PlacesSheet: View {
    @ObservedObject var store: PlacesStore
    @Binding var isShowing: Bool
    @Binding var searchQuery: String
    let onNavigate: (CLLocationCoordinate2D, String) -> Void
    let onSetHome: (String) -> Void

    @State private var showAddFav = false
    @State private var showSetHome = false
    @State private var newName = ""
    @State private var activeTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.2))
                .frame(width: 40, height: 4).padding(.top, 14)

            // Header
            HStack {
                Text("My Places")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                Spacer()
                Button(action: { isShowing = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            // Tabs
            HStack(spacing: 0) {
                tabBtn("house.fill", "Home", 0)
                tabBtn("star.fill", "Favourites", 1)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 12) {
                    if activeTab == 0 {
                        homeTab
                    } else {
                        favsTab
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
            }
        }
        .background(Color.b1)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .alert("Set Home Address", isPresented: $showSetHome) {
            TextField("Enter your home address", text: $newName)
                .autocorrectionDisabled()
            Button("Search & Set") { onSetHome(newName); isShowing = false }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: { Text("Type your home address and we'll find it") }
        .alert("Add Favourite", isPresented: $showAddFav) {
            TextField("Search for a place", text: $newName)
                .autocorrectionDisabled()
            Button("Add") {
                searchQuery = newName
                isShowing = false
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: { Text("Search for a place to add to favourites") }
    }

    var homeTab: some View {
        VStack(spacing: 12) {
            if let h = store.home {
                // Home set
                placeCard(
                    icon: "house.fill",
                    iconColor: .g1,
                    name: h.name,
                    address: h.address,
                    onGo: {
                        isShowing = false
                        onNavigate(h.coordinate, h.name)
                    },
                    onDelete: { store.removeHome() }
                )
            } else {
                // No home set
                VStack(spacing: 16) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 40)).foregroundColor(.g1.opacity(0.4))
                    Text("No home set")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Text("Set your home address for quick one-tap navigation")
                        .font(.system(size: 13)).foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    Button(action: { newName = ""; showSetHome = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text("Set Home Address")
                        }
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                        .cornerRadius(14)
                    }
                }
                .padding(24)
                .background(Color.b2).cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.g1.opacity(0.2), lineWidth: 1))
            }

            if store.home != nil {
                Button(action: { newName = ""; showSetHome = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil.circle.fill")
                        Text("Change Home")
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.g1)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.b3).cornerRadius(13)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.g1.opacity(0.25), lineWidth: 1))
                }
            }
        }
    }

    var favsTab: some View {
        VStack(spacing: 12) {
            // Add button
            Button(action: { newName = ""; showAddFav = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Favourite Place")
                }
                .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                .cornerRadius(14)
            }

            if store.favourites.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 36)).foregroundColor(.g1.opacity(0.3))
                    Text("No favourites yet")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text("Add your favourite places for quick access")
                        .font(.system(size: 13)).foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(Color.b2).cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.g1.opacity(0.2), lineWidth: 1))
            } else {
                ForEach(store.favourites) { fav in
                    placeCard(
                        icon: "star.fill",
                        iconColor: .yellow,
                        name: fav.name,
                        address: fav.address,
                        onGo: {
                            isShowing = false
                            onNavigate(fav.coordinate, fav.name)
                        },
                        onDelete: {
                            if let idx = store.favourites.firstIndex(where: { $0.id == fav.id }) {
                                store.favourites.remove(at: idx)
                            }
                        }
                    )
                }
            }
        }
    }

    func placeCard(icon: String, iconColor: Color, name: String, address: String, onGo: @escaping ()->Void, onDelete: @escaping ()->Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(iconColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text(address.isEmpty ? "Saved location" : address)
                    .font(.system(size: 12)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 14)).foregroundColor(.red.opacity(0.7))
                }
                Button(action: onGo) {
                    Text("Go")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                        .cornerRadius(20)
                }
            }
        }
        .padding(14)
        .background(Color.b2).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.g1.opacity(0.15), lineWidth: 1))
    }

    func tabBtn(_ icon: String, _ label: String, _ idx: Int) -> some View {
        Button(action: { activeTab = idx }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(activeTab == idx ? .black : .g1)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(activeTab == idx
                ? LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing)
                : LinearGradient(colors:[Color.b3, Color.b3], startPoint:.leading, endPoint:.trailing))
            .cornerRadius(12)
        }
    }
}

// MARK: - Splash
struct Splash: View {
    @State private var sc: CGFloat = 0.8
    @State private var op: Double  = 0
    @State private var pr: CGFloat = 0
    var body: some View {
        ZStack {
            Color.b1.ignoresSafeArea()
            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 30)
                        .fill(Color.b2).frame(width: 120, height: 120)
                        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.g1.opacity(0.45), lineWidth: 1.5))
                        .shadow(color: Color.g1.opacity(0.4), radius: 40)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors:[.g2,.g1], startPoint:.top, endPoint:.bottom))
                }
                VStack(spacing: 8) {
                    Text("Toska")
                        .font(.system(size: 46, weight: .bold, design: .serif))
                        .foregroundStyle(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                    Text("INTELLIGENT NAVIGATION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gray.opacity(0.8)).tracking(3.5)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(width: 130, height: 3)
                    Capsule()
                        .fill(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                        .frame(width: 130*pr, height: 3)
                }.padding(.top, 8)
            }
            .scaleEffect(sc).opacity(op)
            .onAppear {
                withAnimation(.spring(response:0.5, dampingFraction:0.7)){sc=1; op=1}
                withAnimation(.linear(duration:2.6)){pr=1}
            }
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var lm = LocationManager()
    @StateObject private var nm = NavigationManager()
    @StateObject private var store = PlacesStore()

    @State private var destCoord: CLLocationCoordinate2D? = nil
    @State private var destName  = ""
    @State private var query     = ""
    @State private var splash    = true
    @State private var showPanel = true
    @State private var showNearby = false
    @State private var showPlaces = false
    @FocusState private var focused: Bool



    var body: some View {
        ZStack(alignment: .bottom) {

            // MAP
            ToskaMapView(
                region:      $lm.mapRegion,
                polyline:    nm.polyline,
                destCoord:   destCoord,
                isNavigating: nm.isNavigating,
                cameras:     nm.cameras,
                fuelPlaces:  nm.nearbyFuel,
                parkPlaces:  nm.nearbyParking
            )
            .ignoresSafeArea()
            .onReceive(lm.$coordinate) { c in
                guard let c = c else { return }
                nm.updateProgress(userCoord: c, speed: lm.speed)
            }
            .onTapGesture {
                if nm.isNavigating { withAnimation { showPanel.toggle() } }
            }

            // TOP BAR
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    // Logo
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.b2).frame(width: 38, height: 38)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.g1.opacity(0.4), lineWidth: 1))
                            Image(systemName: "location.north.fill")
                                .font(.system(size: 17, weight: .bold)).foregroundColor(.g1)
                        }
                        Text("Toska")
                            .font(.system(size: 23, weight: .bold, design: .serif))
                            .foregroundStyle(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if lm.speed > 3 { Pill(text: "\(Int(lm.speed)) km/h", on: true, accent: true) }
                        Pill(text: lm.gpsText, on: lm.gpsOK)
                        if nm.isNavigating { Pill(text: "Live", on: true, accent: true) }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 56).padding(.bottom, 4)
                .background(LinearGradient(colors:[Color.b1.opacity(0.97),.clear], startPoint:.top, endPoint:.bottom))

                // Camera alert
                if nm.cameraAlertActive, let cam = nm.nearestCamera {
                    CameraAlert(camera: cam, distance: nm.cameraDistance, speed: lm.speed)
                        .transition(.move(edge:.top).combined(with:.opacity))
                        .padding(.top, 2)
                }

                // Nav banner
                if nm.isNavigating && showPanel {
                    NavBanner(nm: nm, speed: lm.speed)
                        .transition(.move(edge:.top).combined(with:.opacity))
                        .padding(.top, 2)
                }

                Spacer()
            }
            .ignoresSafeArea()
            .animation(.spring(response:0.35, dampingFraction:0.8), value: nm.isNavigating)
            .animation(.spring(response:0.35, dampingFraction:0.8), value: nm.cameraAlertActive)

            // ARRIVED
            if nm.hasArrived {
                ArrivedView {
                    nm.reset(); destCoord = nil; destName = ""
                }
                .transition(.scale(scale:0.9).combined(with:.opacity))
                .zIndex(9).padding(.bottom, 120)
            }

            // LOCATE BUTTON
            if !nm.isNavigating {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: centreMe) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Color.b2).frame(width: 48, height: 48)
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.g1.opacity(0.3), lineWidth: 1))
                                    .shadow(color:.black.opacity(0.4), radius:8, y:4)
                                Image(systemName: "location.fill").font(.system(size: 18)).foregroundColor(.blue)
                            }
                        }
                        .padding(.trailing, 16).padding(.bottom, 320)
                    }
                }
            }

            // LOCATION DENIED BANNER
            if lm.denied {
                VStack {
                    HStack(spacing: 12) {
                        Image(systemName: "location.slash.fill").foregroundColor(.orange).font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Location Denied").font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            Text("Settings → Toska → Location → While Using App").font(.system(size: 11)).foregroundColor(.gray)
                        }
                        Spacer()
                        Button("Fix") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }.font(.system(size: 13, weight: .bold)).foregroundColor(.g1)
                    }
                    .padding(16).background(Color.b2).cornerRadius(16)
                    .overlay(RoundedRectangle(cornerRadius:16).stroke(Color.orange.opacity(0.5), lineWidth:1))
                    .padding(.horizontal, 16)
                    Spacer()
                }.padding(.top, 120).zIndex(6)
            }

            // BOTTOM PANEL
            if showPanel {
                VStack(spacing: 12) {
                    // Handle
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                        .frame(width: 40, height: 4).padding(.top, 10)

                    // Route card
                    // Add to favourites when route exists
                    if nm.hasRoute && !destName.isEmpty {
                        Button(action: addCurrentDestAsFav) {
                            HStack(spacing: 6) {
                                Image(systemName: "star.fill")
                                Text("Save to Favourites")
                            }
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.g1)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.b3).cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius:12).stroke(Color.g1.opacity(0.25), lineWidth:1))
                        }
                    }
                    if nm.hasRoute {
                        RouteCard(nm: nm)
                            .transition(.move(edge:.top).combined(with:.opacity))
                    }

                    if !nm.isNavigating {
                        // Search bar
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.g1).font(.system(size: 16))
                            TextField("Where to, Hassan?", text: $query)
                                .foregroundColor(.white).font(.system(size: 15))
                                .focused($focused).submitLabel(.search)
                                .onSubmit(doSearch).autocorrectionDisabled()
                            if !query.isEmpty {
                                Button(action: clearAll) {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray).font(.system(size: 17))
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(Color.b3).cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius:14).stroke(
                            focused ? Color.g1.opacity(0.8) : Color.g1.opacity(0.2), lineWidth:1))

                        // Action buttons
                        if nm.hasRoute {
                            HStack(spacing: 10) {
                                Button(action: clearAll) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark")
                                        Text("Clear")
                                    }
                                    .font(.system(size:14, weight:.semibold)).foregroundColor(.gray)
                                    .frame(maxWidth:.infinity).padding(.vertical, 13)
                                    .background(Color.b3).cornerRadius(13)
                                }
                                Button(action: {
                                    if let c = lm.coordinate { nm.searchNearby(coord: c) }
                                    showNearby = true
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "mappin.and.ellipse")
                                        Text("Nearby")
                                    }
                                    .font(.system(size:14, weight:.semibold)).foregroundColor(.g1)
                                    .frame(maxWidth:.infinity).padding(.vertical, 13)
                                    .background(Color.b3).cornerRadius(13)
                                    .overlay(RoundedRectangle(cornerRadius:13).stroke(Color.g1.opacity(0.3), lineWidth:1))
                                }
                                Button(action: startNav) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "car.fill")
                                        Text("Start")
                                    }
                                    .font(.system(size:15, weight:.bold)).foregroundColor(.black)
                                    .frame(maxWidth:.infinity).padding(.vertical, 13)
                                    .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                                    .cornerRadius(13)
                                }
                            }
                        } else {
                            // Get route button
                            Button(action: doSearch) {
                                HStack(spacing: 8) {
                                    if nm.isCalculating {
                                        ProgressView().tint(Color.b1).scaleEffect(0.85)
                                        Text("Calculating...")
                                    } else {
                                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                        Text("Get Precise Route")
                                    }
                                }
                                .font(.system(size:16, weight:.bold)).foregroundColor(.black)
                                .frame(maxWidth:.infinity).padding(.vertical, 15)
                                .background(LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing))
                                .cornerRadius(14)
                                .shadow(color:.g1.opacity(0.3), radius:8, y:3)
                            }
                            .disabled(query.isEmpty || nm.isCalculating)
                            .opacity(query.isEmpty ? 0.4 : 1)

                            // Nearby button (standalone)
                            Button(action: {
                                if let c = lm.coordinate { nm.searchNearby(coord: c) }
                                showNearby = true
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "fuelpump.fill")
                                    Text("Fuel & Parking Nearby")
                                }
                                .font(.system(size:14, weight:.semibold)).foregroundColor(.g1)
                                .frame(maxWidth:.infinity).padding(.vertical, 12)
                                .background(Color.b3).cornerRadius(13)
                                .overlay(RoundedRectangle(cornerRadius:13).stroke(Color.g1.opacity(0.25), lineWidth:1))
                            }

                            // Home + Favourites buttons
                            HStack(spacing: 10) {
                                // Home button
                                Button(action: {
                                    if let h = store.home {
                                        if let u = lm.coordinate {
                                            nm.calculateRoute(from: u, to: h.coordinate, destName: h.name)
                                            destCoord = h.coordinate
                                            destName  = h.name
                                            query     = h.name
                                        }
                                    } else {
                                        showPlaces = true
                                    }
                                }) {
                                    HStack(spacing: 7) {
                                        Image(systemName: "house.fill")
                                            .font(.system(size: 14))
                                        Text(store.home != nil ? "Home" : "Set Home")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundColor(store.home != nil ? .black : .g1)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(store.home != nil
                                        ? LinearGradient(colors:[.g1,.g2], startPoint:.leading, endPoint:.trailing)
                                        : LinearGradient(colors:[Color.b3,Color.b3], startPoint:.leading, endPoint:.trailing))
                                    .cornerRadius(13)
                                    .overlay(store.home == nil ? RoundedRectangle(cornerRadius:13).stroke(Color.g1.opacity(0.3), lineWidth:1) : nil)
                                }

                                // Favourites button
                                Button(action: { showPlaces = true }) {
                                    HStack(spacing: 7) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 14))
                                        Text("Favourites")
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    .foregroundColor(.g1)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.b3).cornerRadius(13)
                                    .overlay(RoundedRectangle(cornerRadius:13).stroke(Color.g1.opacity(0.3), lineWidth:1))
                                }
                            }
                        }
                    } else {
                        // During navigation: just stop button
                        Button(action: stopNav) {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                Text("Stop Navigation")
                            }
                            .font(.system(size:16, weight:.bold)).foregroundColor(.white)
                            .frame(maxWidth:.infinity).padding(.vertical, 14)
                            .background(Color(red:0.65, green:0.1, blue:0.1))
                            .cornerRadius(14)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 34)
                .background(
                    Color.b1
                        .overlay(Rectangle().fill(Color.g1.opacity(0.03)))
                        .overlay(Rectangle().fill(Color.g1.opacity(0.15)).frame(height:1), alignment:.top)
                )
                .cornerRadius(28)
                .shadow(color:.black.opacity(0.5), radius:20, y:-5)
                .animation(.spring(response:0.4, dampingFraction:0.8), value: nm.hasRoute)
                .animation(.spring(response:0.4, dampingFraction:0.8), value: nm.isNavigating)
            }

            // SPLASH
            if splash {
                Splash().transition(.opacity).zIndex(10)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline:.now()+3.2) {
                            withAnimation(.easeInOut(duration:0.7)){splash=false}
                        }
                    }
            }
        }
        .ignoresSafeArea(edges:.bottom)
        .sheet(isPresented: $showPlaces) {
            PlacesSheet(
                store: store,
                isShowing: $showPlaces,
                searchQuery: $query,
                onNavigate: navigateTo,
                onSetHome: setHome
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showNearby) {
            NearbySheet(nm: nm, onNavigate: navigateTo, isShowing: $showNearby)
                .preferredColorScheme(.dark)
        }
        .alert("Navigation Error", isPresented:$nm.showError) {
            Button("OK"){ nm.showError=false }
        } message: { Text(nm.errorMsg) }
        .animation(.spring(response:0.4, dampingFraction:0.8), value: nm.hasArrived)
        .animation(.spring(response:0.35, dampingFraction:0.8), value: showPanel)
    }

    // MARK: - Actions
    func doSearch() {
        guard !query.isEmpty else { return }
        focused = false
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        r.region               = lm.mapRegion
        MKLocalSearch(request:r).start { res, _ in
            guard let item = res?.mapItems.first else { return }
            DispatchQueue.main.async {
                self.destCoord = item.placemark.coordinate
                self.destName  = item.name ?? self.query
                if let u = self.lm.coordinate {
                    self.nm.calculateRoute(from:u, to:item.placemark.coordinate, destName:self.destName)
                }
            }
        }
    }

    func navigateTo(_ coord: CLLocationCoordinate2D, _ name: String) {
        destCoord = coord
        destName  = name
        query     = name
        if let u = lm.coordinate {
            nm.calculateRoute(from: u, to: coord, destName: name)
        }
    }

    func startNav() {
        nm.startNavigation()
        lm.beginNavigation()
        showPanel = true
    }

    func stopNav() {
        nm.stopNavigation()
        lm.endNavigation()
    }

    func centreMe() {
        guard let c = lm.coordinate else { return }
        withAnimation {
            lm.mapRegion = MKCoordinateRegion(
                center: c,
                span:   MKCoordinateSpan(latitudeDelta:0.008, longitudeDelta:0.008)
            )
        }
    }

    func setHome(_ address: String) {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = address
        MKLocalSearch(request: r).start { res, _ in
            guard let item = res?.mapItems.first else { return }
            DispatchQueue.main.async {
                let place = SavedPlace(
                    name: item.name ?? address,
                    address: item.placemark.thoroughfare ?? address,
                    coordinate: item.placemark.coordinate,
                    isHome: true
                )
                self.store.setHome(place)
            }
        }
    }

    func addCurrentDestAsFav() {
        guard let c = destCoord, !destName.isEmpty else { return }
        let place = SavedPlace(name: destName, address: "", coordinate: c)
        store.addFavourite(place)
    }

    func clearAll() {
        query=""
        destCoord=nil
        destName=""
        nm.reset()
        lm.endNavigation()
        if let c = lm.coordinate {
            lm.mapRegion = MKCoordinateRegion(
                center: c,
                span:   MKCoordinateSpan(latitudeDelta:0.008, longitudeDelta:0.008)
            )
        }
    }
}

#Preview { ContentView() }
