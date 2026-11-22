import AVFoundation
import CoreLocation
import Foundation
import MapKit
import UIKit
import UserNotifications

/// One thing the voice assistant can do. Modelled on hailo-apps' Voice-to-Action demo (v2a_demo/tools):
/// `descriptions` are compared with the request by MiniLM (sentence embeddings) to pick the tool, a tool
/// needs at least `threshold` cosine similarity, and `prompt` (if any) asks the language model to pull
/// the parameters out of the request as JSON.
struct AssistantTool: Identifiable {
    let name: String
    let title: String
    let descriptions: [String]
    let threshold: Float
    let prompt: String?
    let run: @MainActor ([String: Any], AssistantContext) async throws -> String
    /// Wording that picks this tool before MiniLM is asked (a regular expression, case-insensitive).
    /// MiniLM's sentence embeddings follow the topic of a request more than its command, so "search the
    /// web for <topic>" scores low against any search description; explicit phrases fix that.
    var trigger: String? = nil
    var id: String { name }
}

/// What tools may use: the app state (models, the language model) and the original request.
struct AssistantContext {
    let studio: StudioModel
    let request: String
}

enum AssistantTools {
    static let all: [AssistantTool] = [none, explain, weather, travel, torch, system, memory, timer, clock, search]

    // MARK: none (general question: the language model answers briefly)

    static let none = AssistantTool(
        name: "none", title: "Answer",
        descriptions: ["General question or conversation", "Tell me something", "Explain a concept", "Chat"],
        threshold: 0, prompt: nil,
        run: { _, context in
            guard let model = context.studio.assistantModel else { return "I need a language model for that. Choose one in the assistant's settings." }
            let llm = try await context.studio.languageModel(model, keepSpeech: true)
            var parameters = LlamaEngine.Parameters()
            parameters.maxTokens = 160
            parameters.temperature = 0.3
            let question = context.request + (model.title.hasPrefix("Qwen3") ? " /no_think" : "")
            let box = TextBox()
            _ = try await llm.generate([
                .init(role: "system", content: "You are a voice assistant. Answer in one or two short spoken sentences, no lists, no markdown."),
                .init(role: "user", content: question),
            ], parameters: parameters) { box.append($0) }
            return visibleAnswer(box.text)
        })

    // MARK: explain_tools

    static let explain = AssistantTool(
        name: "explain_tools", title: "What I can do",
        descriptions: ["What can you do?", "Which tools do you have?", "Help, list your abilities", "What are your features?"],
        threshold: 0.35, prompt: nil,
        run: { _, _ in
            "I can tell you the weather in a city, how long a trip takes, search the web, switch the torch on or off, check this device, remember details about people, set a timer, tell the time, or answer a general question."
        })

    // MARK: get_weather (Open-Meteo: free, no account; the city name is sent to it)

    static let weather = AssistantTool(
        name: "get_weather", title: "Weather",
        descriptions: ["Ask about the weather in a city", "Check current weather conditions for a location",
                       "Weather forecast for today or tomorrow", "Ask about temperature in a city",
                       "Ask if it will rain or be sunny in a place", "Umbrella or rain related questions for a city",
                       "Questions about hot or cold weather", "Ask about wind, humidity, or clouds in a city"],
        threshold: 0.35,
        prompt: """
        Extract parameters from the user's weather request as a JSON object with exactly these fields:
        - "location": the city name, spelled as the user said it.
        - "date": only "today", "tomorrow" or "YYYY-MM-DD". This morning, tonight, later today -> "today".
        Examples:
        "Will it rain in Lisbon tomorrow?" -> {"location": "Lisbon", "date": "tomorrow"}
        "How cold is it in Toronto?" -> {"location": "Toronto", "date": "today"}
        Output only the JSON object.
        """,
        run: { params, _ in
            guard let location = params["location"] as? String, !location.isEmpty else { return "Which city?" }
            let date = (params["date"] as? String) ?? "today"
            return try await OpenMeteo.forecast(city: location, day: date)
        })

    // MARK: get_travel_time (Apple Maps)

    static let travel = AssistantTool(
        name: "get_travel_time", title: "Travel time",
        descriptions: ["How long does it take to get from one place to another?", "What is the travel time or ETA between two locations?",
                       "How many minutes will the journey take?", "Commute time from home to work or any other place.",
                       "Time to reach a destination by car, bike, or on foot.", "How far is it to a place?"],
        threshold: 0.45,
        prompt: """
        Extract parameters from the user's travel time request as a JSON object with exactly these fields:
        - "origin": home/house/my place -> "home", work/office -> "work", no starting place or "here" -> "current_location".
        - "destination": the destination, spelled as the user said it.
        - "mode": "driving", "walking" or "cycling" (car/drive -> driving, walk/on foot -> walking, bike -> cycling). Default "driving".
        Examples:
        "How long from home to the airport?" -> {"origin": "home", "destination": "the airport", "mode": "driving"}
        "How long to walk to the station?" -> {"origin": "current_location", "destination": "the station", "mode": "walking"}
        Output only the JSON object.
        """,
        run: { params, _ in
            guard let destination = params["destination"] as? String, !destination.isEmpty else { return "Where to?" }
            return try await AppleMapsTravel.time(from: (params["origin"] as? String) ?? "current_location", to: destination,
                                                  mode: (params["mode"] as? String) ?? "driving")
        })

    // MARK: control_torch (the camera flash, like hailo-apps' LED tool)

    static let torch = AssistantTool(
        name: "control_torch", title: "Torch",
        descriptions: ["Turn the flashlight on", "Switch off the torch", "Turn on the light", "Light off",
                       "Toggle the flashlight", "Make it brighter, I need light"],
        threshold: 0.5,
        prompt: """
        Extract the user's torch request as a JSON object with one field:
        - "state": "on" or "off".
        Examples: "Turn on the flashlight" -> {"state": "on"}  "Lights off" -> {"state": "off"}
        Output only the JSON object.
        """,
        run: { params, _ in
            let on = ((params["state"] as? String) ?? "on").lowercased() != "off"
            guard let camera = AVCaptureDevice.default(for: .video), camera.hasTorch else { return "This device has no torch." }
            try camera.lockForConfiguration()
            camera.torchMode = on ? .on : .off
            camera.unlockForConfiguration()
            return on ? "Torch on." : "Torch off."
        })

    // MARK: system_check

    static let system = AssistantTool(
        name: "system_check", title: "Device check",
        descriptions: ["Check the battery level", "How is the device doing?", "System status", "How much storage is free?",
                       "Is the device hot?", "Which models are installed?"],
        threshold: 0.35, prompt: nil,
        run: { _, context in
            UIDevice.current.isBatteryMonitoringEnabled = true
            var parts: [String] = []
            let battery = UIDevice.current.batteryLevel
            if battery >= 0 { parts.append("Battery at \(Int(battery * 100)) percent") }
            if let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                parts.append(String(format: "%.0f gigabytes free", Double(free) / 1e9))
            }
            let thermal: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: thermal = "temperature normal"
            case .fair: thermal = "slightly warm"
            case .serious: thermal = "hot"
            case .critical: thermal = "very hot"
            @unknown default: thermal = "temperature unknown"
            }
            parts.append(thermal)
            parts.append("\(context.studio.installed.count) vision models installed")
            return parts.joined(separator: ", ") + "."
        })

    // MARK: data_storage (kept on this device, Documents/assistant-memory.json)

    static let memory = AssistantTool(
        name: "data_storage", title: "Memory",
        descriptions: ["Remember details like phone numbers and emails", "Remember John's phone number is 555 1234",
                       "Save Maria's email address", "Note my friend's birthday", "What is John's phone number?",
                       "What is Sarah's email address?", "Tell me Peter's birthday", "What's my sister's address?",
                       "Do you remember Anna's phone?", "Recall the ID number I saved for Tom"],
        threshold: 0.48,
        prompt: """
        Extract parameters from the user's memory request as a JSON object with exactly these fields:
        - "operation": "store" for remember/save/note, "retrieve" for what is/recall/tell me.
        - "subject": the person's name with a capital first letter; "User" for me/my/I.
        - "key": phone, email, address, birthday, id_number, or a short field name.
        - "value": the data to store; null when retrieving.
        Examples:
        "Remember John's phone number is 123 456 7890" -> {"operation": "store", "subject": "John", "key": "phone", "value": "123 456 7890"}
        "What is Sarah's email?" -> {"operation": "retrieve", "subject": "Sarah", "key": "email", "value": null}
        Output only the JSON object.
        """,
        run: { params, _ in
            let subject = (params["subject"] as? String) ?? "User"
            let key = ((params["key"] as? String) ?? "note").lowercased()
            if ((params["operation"] as? String) ?? "") == "store", let value = params["value"] as? String, !value.isEmpty {
                AssistantMemory.store(subject: subject, key: key, value: value)
                return "Saved \(subject)'s \(key.replacingOccurrences(of: "_", with: " "))."
            }
            if let value = AssistantMemory.retrieve(subject: subject, key: key) {
                return "\(subject)'s \(key.replacingOccurrences(of: "_", with: " ")) is \(value)."
            }
            return "I have nothing saved for \(subject)'s \(key.replacingOccurrences(of: "_", with: " "))."
        },
        trigger: #"\b(remember|memori[sz]e|save|note down|recall)\b|\b\w+'s (phone|number|mobile|email|e-mail|address|birthday|id)\b"#)

    // MARK: set_timer (a local notification)

    static let timer = AssistantTool(
        name: "set_timer", title: "Timer",
        descriptions: ["Set a timer", "Remind me in ten minutes", "Start a countdown", "Alarm in five minutes",
                       "Timer for the pasta", "Wake me in half an hour"],
        threshold: 0.45,
        prompt: """
        Extract the timer request as a JSON object with exactly these fields:
        - "seconds": the duration in seconds as a number.
        - "label": what the timer is for, or "Timer".
        Examples: "Set a timer for 10 minutes for the pasta" -> {"seconds": 600, "label": "pasta"}
        "Remind me in an hour and a half" -> {"seconds": 5400, "label": "Timer"}
        Output only the JSON object.
        """,
        run: { params, _ in
            let seconds = (params["seconds"] as? NSNumber)?.doubleValue ?? Double((params["seconds"] as? String) ?? "") ?? 0
            guard seconds >= 1 else { return "For how long?" }
            let label = (params["label"] as? String) ?? "Timer"
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return "Notifications are off for Artelico, so I can't set a timer." }
            let content = UNMutableNotificationContent()
            content.title = label == "Timer" ? "Timer" : "Timer: \(label)"
            content.body = "Time is up."
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)))
            return "Timer set for \(Self.spoken(seconds))."
        })

    // MARK: get_time

    static let clock = AssistantTool(
        name: "get_time", title: "Time and date",
        descriptions: ["What time is it?", "What is today's date?", "Which day is it today?", "Tell me the time"],
        threshold: 0.45, prompt: nil,
        run: { _, _ in
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE d MMMM, HH:mm"
            return "It's \(formatter.string(from: Date()))."
        })

    // MARK: web_search (your own SearXNG if set, else a small built-in meta-search)

    static let search = AssistantTool(
        name: "web_search", title: "Web search",
        descriptions: ["Search the web for something", "Look it up online", "Find the latest news about a topic",
                       "Google this for me", "What does the internet say about", "Search for information about a company or person",
                       "Find recent results about an event"],
        threshold: 0.42,
        prompt: """
        Extract the web search from the user's request as a JSON object with one field:
        - "query": a short search query (a few keywords), in the user's language.
        Examples: "Search the web for the opening hours of the Louvre" -> {"query": "Louvre opening hours"}
        "Look up the latest news about the Hailo 10H" -> {"query": "Hailo-10H news"}
        Output only the JSON object.
        """,
        run: { params, context in
            let query = ((params["query"] as? String) ?? context.request).trimmingCharacters(in: .whitespaces)
            let results = try await MetaSearch.search(query)
            guard !results.isEmpty else { return "I found nothing for \(query)." }
            guard let model = context.studio.assistantModel else {
                return "Top result: " + results[0].title + ". " + results[0].snippet
            }
            let llm = try await context.studio.languageModel(model, keepSpeech: true)
            let sources = results.prefix(5).enumerated().map { "[\($0.offset + 1)] \($0.element.title) (\($0.element.site)): \($0.element.snippet)" }.joined(separator: "\n")
            var parameters = LlamaEngine.Parameters()
            parameters.maxTokens = 180
            parameters.temperature = 0.2
            let box = TextBox()
            _ = try await llm.generate([
                .init(role: "system", content: "You are a voice assistant. Answer the question from the search results only, in two or three short spoken sentences, and say which site it comes from. If the results do not answer it, say so."),
                .init(role: "user", content: "Question: \(context.request)\nSearch results:\n\(sources)" + (model.title.hasPrefix("Qwen3") ? " /no_think" : "")),
            ], parameters: parameters) { box.append($0) }
            return visibleAnswer(box.text)
        },
        trigger: #"\b(search|look (it |this |that )?up|google|on the (web|internet)|online|latest news|news (about|on))\b"#)

    static func spoken(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        if s > 0 && h == 0 { parts.append("\(s) second\(s == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }
}

/// Collects streamed text from the language model.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ piece: String) { lock.withLock { value += piece } }
    var text: String { lock.withLock { value } }
}

/// Personal details the assistant was asked to remember, kept in Documents/assistant-memory.json.
enum AssistantMemory {
    private static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("assistant-memory.json")
    }
    private static func load() -> [String: [String: String]] {
        (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))) ?? [:]
    }
    static func store(subject: String, key: String, value: String) {
        var all = load()
        all[subject, default: [:]][key] = value
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
    static func retrieve(subject: String, key: String) -> String? {
        let all = load()
        let person = all.first { $0.key.lowercased() == subject.lowercased() }?.value
        return person?[key]
    }
}

/// Weather from Open-Meteo (open-meteo.com): free, no account. Only the city name and its coordinates
/// are sent.
enum OpenMeteo {
    static func forecast(city: String, day: String) async throws -> String {
        var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        let (geoData, _) = try await URLSession.shared.data(from: geo.url!)
        guard let place = ((try JSONSerialization.jsonObject(with: geoData) as? [String: Any])?["results"] as? [[String: Any]])?.first,
              let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double else {
            return "I couldn't find \(city)."
        }
        let name = (place["name"] as? String) ?? city
        var forecast = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        forecast.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "16"),
        ]
        let (data, _) = try await URLSession.shared.data(from: forecast.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daily = json["daily"] as? [String: Any], let dates = daily["time"] as? [String] else {
            return "The weather service did not answer."
        }
        let index: Int
        switch day.lowercased() {
        case "today": index = 0
        case "tomorrow": index = 1
        default: index = dates.firstIndex(of: day) ?? 0
        }
        guard index < dates.count else { return "I only have the next sixteen days." }
        func value(_ key: String) -> Double? { ((daily[key] as? [Any])?[index] as? NSNumber)?.doubleValue }
        let high = value("temperature_2m_max").map { Int($0.rounded()) }
        let low = value("temperature_2m_min").map { Int($0.rounded()) }
        let rain = value("precipitation_probability_max").map { Int($0.rounded()) }
        let code = Int(value("weather_code") ?? -1)
        var sentence = "\(index == 0 ? "Today" : index == 1 ? "Tomorrow" : "On \(dates[index])") in \(name): \(describe(code))"
        if index == 0, let current = (json["current"] as? [String: Any])?["temperature_2m"] as? Double {
            sentence += ", now \(Int(current.rounded())) degrees"
        }
        if let high, let low { sentence += ", between \(low) and \(high) degrees" }
        if let rain { sentence += ", \(rain) percent chance of rain" }
        return sentence + "."
    }

    /// WMO weather codes, as Open-Meteo documents them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1, 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "fog"
        case 51, 53, 55, 56, 57: return "drizzle"
        case 61, 63, 65, 66, 67: return "rain"
        case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95, 96, 99: return "thunderstorms"
        default: return "mixed weather"
        }
    }
}

/// Travel time with Apple Maps (MapKit). "home" and "work" are addresses saved in the assistant's settings;
/// "current_location" asks for the location while the app is in use.
enum AppleMapsTravel {
    @MainActor
    static func time(from origin: String, to destination: String, mode: String) async throws -> String {
        let request = MKDirections.Request()
        guard let start = try await place(origin), let end = try await place(destination) else {
            return "I couldn't find \(destination)."
        }
        request.source = start
        request.destination = end
        request.transportType = mode == "walking" || mode == "cycling" ? .walking : .automobile
        let route = try await MKDirections(request: request).calculate().routes.first
        guard let route else { return "I couldn't find a route to \(destination)." }
        var seconds = route.expectedTravelTime
        if mode == "cycling" { seconds = route.distance / (15_000.0 / 3600) }   // Apple Maps has no cycling routes here: 15 km/h
        let verb = mode == "walking" ? "Walking" : mode == "cycling" ? "Cycling" : "Driving"
        return String(format: "%@ to %@ takes about %@, %.1f kilometres.", verb, destination, AssistantTools.spoken(seconds), route.distance / 1000)
    }

    @MainActor
    private static func place(_ name: String) async throws -> MKMapItem? {
        switch name {
        case "current_location":
            return try await CurrentLocation.shared.mapItem()
        case "home", "work":
            guard let address = UserDefaults.standard.string(forKey: "assistant.\(name)"), !address.isEmpty else { return nil }
            return try await search(address)
        default:
            return try await search(name)
        }
    }

    @MainActor
    private static func search(_ text: String) async throws -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let here = try? await CurrentLocation.shared.mapItem() {
            request.region = MKCoordinateRegion(center: here.placemark.coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        }
        return try await MKLocalSearch(request: request).start().mapItems.first
    }
}

/// One location fix while the app is in use.
@MainActor
final class CurrentLocation: NSObject, CLLocationManagerDelegate {
    static let shared = CurrentLocation()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []

    func mapItem() async throws -> MKMapItem {
        let location = try await fix()
        return MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }

    private func fix() async throws -> CLLocation {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let pending = self.waiting
            self.waiting = []
            pending.forEach { $0.resume(returning: location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let pending = self.waiting
            self.waiting = []
            pending.forEach { $0.resume(throwing: error) }
        }
    }
}

/// Web search for the assistant. With a SearXNG address in the assistant's settings it uses that server's
/// JSON API (format=json must be enabled in its settings.yml); otherwise it asks DuckDuckGo's HTML page and
/// Wikipedia's API directly and merges the results - a small meta-search in the spirit of SearXNG.
/// The query goes to whichever of these answers.
enum MetaSearch {
    struct Result: Hashable {
        var title: String
        var url: String
        var snippet: String
        var site: String
    }

    static func search(_ query: String) async throws -> [Result] {
        if let server = UserDefaults.standard.string(forKey: "assistant.searxng"), !server.isEmpty {
            return try await searxng(server, query)
        }
        async let web = (try? await duckDuckGo(query)) ?? []
        async let wiki = (try? await wikipedia(query)) ?? []
        // Interleave the two engines, dropping duplicate addresses.
        var merged: [Result] = []
        var seen = Set<String>()
        let (a, b) = await (web, wiki)
        for i in 0..<max(a.count, b.count) {
            for list in [a, b] where i < list.count && !seen.contains(list[i].url) {
                merged.append(list[i])
                seen.insert(list[i].url)
            }
        }
        return Array(merged.prefix(8))
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request).0
    }

    static func searxng(_ server: String, _ query: String) async throws -> [Result] {
        guard var components = URLComponents(string: server.hasSuffix("/") ? server + "search" : server + "/search") else { return [] }
        components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
        let json = try JSONSerialization.jsonObject(with: try await get(components.url!)) as? [String: Any]
        return ((json?["results"] as? [[String: Any]]) ?? []).prefix(8).compactMap { item in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            return Result(title: title, url: url, snippet: (item["content"] as? String) ?? "", site: URL(string: url)?.host ?? "")
        }
    }

    static func wikipedia(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: query),
                                 .init(name: "format", value: "json"), .init(name: "srlimit", value: "4")]
        let json = try JSONSerialization.jsonObject(with: try await get(components.url!)) as? [String: Any]
        let hits = ((json?["query"] as? [String: Any])?["search"] as? [[String: Any]]) ?? []
        return hits.compactMap { hit in
            guard let title = hit["title"] as? String else { return nil }
            let snippet = ((hit["snippet"] as? String) ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return Result(title: title, url: "https://en.wikipedia.org/wiki/" + title.replacingOccurrences(of: " ", with: "_"),
                          snippet: decodeEntities(snippet), site: "Wikipedia")
        }
    }

    /// DuckDuckGo's plain HTML results page (html.duckduckgo.com), read for titles, links and snippets.
    static func duckDuckGo(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [.init(name: "q", value: query)]
        let html = String(decoding: try await get(components.url!), as: UTF8.self)
        var results: [Result] = []
        let blocks = html.components(separatedBy: "class=\"result__body")
        for block in blocks.dropFirst() {
            guard let link = firstMatch(#"class="result__a"[^>]*href="([^"]+)""#, in: block),
                  let title = firstMatch(#"class="result__a"[^>]*>(.*?)</a>"#, in: block) else { continue }
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block) ?? ""
            var url = decodeEntities(link)
            // Links go through DuckDuckGo's redirect; the real address is in the uddg parameter.
            if let redirect = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let target = redirect.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = target
            }
            guard !url.contains("duckduckgo.com/y.js") else { continue }   // ads
            results.append(Result(title: clean(title), url: url, snippet: clean(snippet), site: URL(string: url)?.host ?? ""))
            if results.count == 6 { break }
        }
        return results
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func clean(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
    }
}
