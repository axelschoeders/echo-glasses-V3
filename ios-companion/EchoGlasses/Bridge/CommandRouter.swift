import Foundation

enum VolumeChange { case up(Int), down(Int), set(Int) }

enum Intent {
    case look(String)                       // describe what the glasses see
    case tv(key: String?, wake: Bool, spoken: String)
    case pc(action: String, spoken: String)
    case tvApp(String)                      // start an app on the TV (Netflix, Disney+)
    case tvVolume(VolumeChange)
    case pcVolume(VolumeChange)
    case shortcut(name: String, spoken: String)   // run an iOS Shortcut (e.g. set a Focus)
    case model3D(String)                    // build a 3D object from the question
    case eufyCamera                        // open configured Eufy RTSP stream on the paired PC
    case uberEats                          // open Uber Eats; checkout remains manual/adult-approved
    case search(String)                     // look it up on the internet
    case openApp(String)
    case refuse(String)
    case chat
}

/// Very small Dutch command router. Anything it doesn't recognise goes to ECHO's AI.
/// Shutdown/restart are deliberately NOT available by voice.
enum CommandRouter {
    static func route(_ raw: String, apps: [String]) -> Intent {
        var t = raw.lowercased()
        for p in ["hey echo", "hé echo", "echo,", "echo"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)); break }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ w: [String]) -> Bool { w.contains { t.contains($0) } }

        // Emergency stop: halts everything ECHO started on the PC (see echo-bridge/echo_security.py)
        if has(["stop alle processen", "stop alle proces"]) {
            return .pc(action: "panic", spoken: "Alles gestopt.")
        }

        if has(["wat zie je", "wat zie ik", "kijk", "beschrijf", "wat is dit", "wat is dat", "lees dit", "wat staat hier"]) {
            return .look(raw)
        }

        if has(["camerabeelden", "eufy camera", "eufy beveiligingscamera", "beelden van de camera"]) {
            return .eufyCamera
        }
        if has(["uber eats", "ubereats"]) {
            return .uberEats
        }

        // Availability: ECHO cannot answer calls itself (iOS does not allow it), but it can run your Shortcuts.
        if has(["weer bereikbaar", "ben er weer", "niet storen uit", "weer beschikbaar"]) {
            return .shortcut(name: "Echo Weer Bereikbaar", spoken: "Welkom terug. Ik haal je telefoon van niet bereikbaar af.")
        }
        if has(["niet bereikbaar", "niet storen", "oproepen over", "gesprekken over", "telefoon over", "even weg"]) {
            return .shortcut(name: "Echo Niet Bereikbaar", spoken: "Ik kan zelf geen gesprekken aannemen, maar ik zet je telefoon op niet bereikbaar.")
        }

        if has(["afsluiten", "uitzetten van de pc", "herstart", "shutdown", "computer uit", "pc uit"]) && has(["pc", "computer", "laptop"]) {
            return .refuse("Afsluiten of herstarten doe ik niet op stem. Gebruik daarvoor de knop in het Bridge-scherm.")
        }

        // Streaming apps on the TV (say "pc/computer/laptop" to mean the PC instead)
        if !has(["pc", "computer", "laptop"]) {
            // Speech recognition may write "net flix" or "netflicks", so also check without spaces.
            let compact = t.replacingOccurrences(of: " ", with: "")
            if ["netflix", "netflicks", "netfliks"].contains(where: { compact.contains($0) }) { return .tvApp("Netflix") }
            if ["disney", "disnee"].contains(where: { compact.contains($0) }) { return .tvApp("Disney+") }
        }

        if has(["tv", "televisie"]) {
            if let v = volume(t) { return .tvVolume(v) }
            if has(["geluid uit", "dempen", "mute", "stil"]) { return .tv(key: "KEY_MUTE", wake: false, spoken: "Geluid gedempt.") }
            if has(["volgende zender"]) { return .tv(key: "KEY_CHUP", wake: false, spoken: "Volgende zender.") }
            if has(["vorige zender"]) { return .tv(key: "KEY_CHDOWN", wake: false, spoken: "Vorige zender.") }
            if has(["pauze", "pauzeer"]) { return .tv(key: "KEY_PAUSE", wake: false, spoken: "Gepauzeerd.") }
            if has(["afspelen", "speel"]) { return .tv(key: "KEY_PLAY", wake: false, spoken: "Speelt af.") }
            if has([" aan", "aanzetten", "opstarten"]) { return .tv(key: nil, wake: true, spoken: "Ik wek de tv.") }
            if has([" uit", "uitzetten"]) { return .tv(key: "KEY_POWER", wake: false, spoken: "Tv uit.") }
        }

        if has(["pc", "computer", "laptop"]) {
            if has(["vergrendel", "op slot"]) { return .pc(action: "lock", spoken: "Vergrendeld.") }
            if has(["slaapstand"]) { return .pc(action: "sleep", spoken: "Slaapstand.") }
            if let v = volume(t) { return .pcVolume(v) }
            if has(["dempen", "mute"]) { return .pc(action: "mute", spoken: "Gedempt.") }
            if has(["pauze", "pauzeer", "afspelen", "speel"]) { return .pc(action: "play_pause", spoken: "Oké.") }
            if has(["volgend"]) { return .pc(action: "next", spoken: "Volgend nummer.") }
            if has(["vorig"]) { return .pc(action: "prev", spoken: "Vorig nummer.") }
        }

        if t.hasPrefix("open ") {
            let wanted = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let app = apps.first(where: { $0.lowercased() == wanted || wanted.contains($0.lowercased()) }) {
                return .openApp(app)
            }
        }
        // "maak een 3d model van een kasteel"
        if has(["3d", "3 d", "drie d", "driedimensionaal"]) && has(["maak", "bouw", "ontwerp", "genereer", "teken", "model", "object"]) {
            return .model3D(raw)
        }

        // Internet: explicit ("zoek ... op", "google") or clearly live info (weather, news, scores).
        if t.hasPrefix("zoek") || has(["opzoeken", "zoek op", "google", "op internet", "online zoeken",
                                       "het weer", "weer in", "weersverwachting", "weerbericht", "nieuws",
                                       "uitslag", "wie heeft gewonnen", "koers van", "wat is de prijs", "actueel"]) {
            return .search(raw)
        }
        return .chat
    }

    // MARK: volume ("harder", "veel zachter", "3 keer harder", "volume 20")

    static func volume(_ t: String) -> VolumeChange? {
        func has(_ w: [String]) -> Bool { w.contains { t.contains($0) } }
        let up = has(["harder", "luider", "omhoog", "verhoog", "hoger"])
        let down = has(["zachter", "stiller", "omlaag", "verlaag", "lager"])
        let words = t.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
        let times = has(["keer", "maal", "stap", "niveau", "streepje"])

        if !up && !down {
            // absolute: "zet de tv op volume twintig"
            guard has(["volume", "geluid"]), let n = firstNumber(words, allowOne: true), n <= 100 else { return nil }
            return .set(n)
        }
        var n = 2
        if has(["heel veel", "enorm", "maximaal"]) { n = 12 }
        else if has(["veel", "flink", "een stuk"]) { n = 6 }
        else if has(["iets", "beetje", "ietsje", "klein"]) { n = 1 }
        if let k = firstNumber(words, allowOne: times), k > 0 { n = min(k, 30) }
        return up ? .up(n) : .down(n)
    }

    private static let units: [String: Int] = ["nul": 0, "een": 1, "één": 1, "twee": 2, "drie": 3, "vier": 4, "vijf": 5, "zes": 6,
        "zeven": 7, "acht": 8, "negen": 9, "tien": 10, "elf": 11, "twaalf": 12, "dertien": 13, "veertien": 14, "vijftien": 15,
        "zestien": 16, "zeventien": 17, "achttien": 18, "negentien": 19]
    private static let tens: [String: Int] = ["twintig": 20, "dertig": 30, "veertig": 40, "vijftig": 50, "zestig": 60,
        "zeventig": 70, "tachtig": 80, "negentig": 90]

    private static func dutchNumber(_ w: String) -> Int? {
        if let n = Int(w) { return n }
        if let n = units[w] ?? tens[w] { return n }
        if w == "honderd" { return 100 }
        if let r = w.range(of: "en", options: .backwards),                       // "vijfentwintig"
           let a = units[String(w[..<r.lowerBound])], let b = tens[String(w[r.upperBound...])] { return a + b }
        return nil
    }

    /// "een" is usually the article ("een beetje"), so only count it as a number when allowed.
    private static func firstNumber(_ words: [String], allowOne: Bool) -> Int? {
        for w in words {
            if (w == "een" || w == "één") && !allowOne { continue }
            if let n = dutchNumber(w) { return n }
        }
        return nil
    }
}
