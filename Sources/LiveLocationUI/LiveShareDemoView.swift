import SwiftUI
import MapKit
import LiveLocation

/// Root view of the demo: four tabs, each backed by real library calls.
public struct LiveShareDemoView: View {
    public enum Tab: String, CaseIterable, Sendable { case sharer, viewers, capacity, gate }

    @State private var model: ScenarioModel
    @State private var selection: Tab

    public init(manifest: CapabilityManifest, initialTab: Tab = .sharer) {
        _model = State(initialValue: ScenarioModel(manifest: manifest))
        _selection = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selection) {
            SharerTab(model: model).tabItem { Label("Sharer", systemImage: "location.fill") }.tag(Tab.sharer)
            ViewersTab(model: model).tabItem { Label("Viewers", systemImage: "person.3.fill") }.tag(Tab.viewers)
            CapacityTab(model: model).tabItem { Label("Capacity", systemImage: "gauge.with.dots.needle.67percent") }.tag(Tab.capacity)
            GateTab(manifest: model.manifest).tabItem { Label("Age rating", systemImage: "checkmark.shield") }.tag(Tab.gate)
        }
        .task { await model.runIfNeeded() }
    }
}

// MARK: - Shared bits

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunningPlaceholder: View {
    let running: Bool
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(running ? "Running the 12-minute scenario…" : "Preparing…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

// MARK: - Sharer

struct SharerTab: View {
    let model: ScenarioModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !model.finished {
                        RunningPlaceholder(running: model.isRunning)
                    } else {
                        let c = model.counters
                        Card(title: "12 min: walk 3 → drive 4 → parked 5") {
                            HStack {
                                Metric(value: "\(c.fixesSeen)", label: "fixes from GPS")
                                Metric(value: "\(c.published)", label: "points sent")
                                Metric(value: "\(c.heartbeats)", label: "heartbeats")
                            }
                            Text("A naive 1 Hz publisher would have sent \(ScenarioModel.scenarioMinutes * 60) points to each viewer.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Card(title: "Why fixes were not sent") {
                            ForEach(SuppressReason.allDisplayed, id: \.self) { reason in
                                let n = c.suppressed[reason] ?? 0
                                HStack {
                                    Text(reason.display).font(.subheadline)
                                    Spacer()
                                    Text("\(n)").font(.subheadline.monospacedDigit().weight(.semibold))
                                }
                            }
                            Text("Battery budget: \(ScenarioModel.demoBudget) movement updates, +1/min. \(model.budgetRemaining) left. Heartbeats never spend it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let cad = model.cadence {
                            Card(title: "Cadence now (parked, battery 18 %)") {
                                Text("Heartbeat every \(Int(cad.heartbeatInterval.seconds))s · presence TTL \(Int(model.presenceTTL.seconds))s")
                                    .font(.subheadline)
                            }
                        }
                        Card(title: "Timeline") {
                            ForEach(model.timeline) { e in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(e.minute).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(e.text).font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Sharing")
        }
    }
}

extension SuppressReason {
    static let allDisplayed: [SuppressReason] = [.tooSoon, .notMoved, .budgetExhausted, .inaccurate, .outOfOrder]
    var display: String {
        switch self {
        case .tooSoon: return "Too soon after last send"
        case .notMoved: return "Hadn't moved far enough"
        case .budgetExhausted: return "Battery budget spent"
        case .inaccurate: return "GPS accuracy too poor"
        case .outOfOrder: return "Out-of-order fix"
        }
    }
}

// MARK: - Viewers

struct ViewersTab: View {
    let model: ScenarioModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !model.finished {
                        RunningPlaceholder(running: model.isRunning)
                    } else {
                        map
                        ForEach(model.viewers) { v in viewerCard(v) }
                        Card(title: "What the relay stores for Alice") {
                            Text(model.sampleCiphertext + "…").font(.caption.monospaced())
                            Text("\(model.copyBytes) bytes per copy. The relay sees share, viewer and sequence — never coordinates.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Viewers")
        }
    }

    private var map: some View {
        let pins = model.viewers.compactMap { v -> (String, CLLocationCoordinate2D)? in
            guard let lat = v.latitude, let lon = v.longitude else { return nil }
            return (v.name, CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return Map {
            MapPolyline(coordinates: model.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                .stroke(.blue.opacity(0.5), lineWidth: 4)
            ForEach(pins.indices, id: \.self) { i in
                Marker("\(pins[i].0) sees", coordinate: pins[i].1).tint(i == 0 ? .green : .orange)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func viewerCard(_ v: ViewerRow) -> some View {
        Card(title: v.name) {
            HStack {
                Circle().fill(color(v.freshness)).frame(width: 10, height: 10)
                Text(v.freshness.label).font(.headline)
                Spacer()
            }
            Text("\(v.channel.rawValue) · \(v.received) decrypted\(v.rejected > 0 ? " · \(v.rejected) rejected" : "")")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func color(_ f: Freshness) -> Color {
        switch f {
        case .live: return .green
        case .delayed: return .yellow
        case .stale, .offline: return .orange
        case .waiting, .ended: return .gray
        }
    }
}

// MARK: - Capacity

struct CapacityTab: View {
    let model: ScenarioModel

    var body: some View {
        let bytes = max(model.copyBytes, 1)
        let e = FanoutLoadModel.estimate(.reference(copyBytes: bytes))
        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Card(title: "Per 1,000 active shares · 3 viewers each") {
                        HStack {
                            Metric(value: fmt(e.publishesPerSecond), label: "publishes / s")
                            Metric(value: fmt(e.copiesPerSecond), label: "sealed copies / s")
                        }
                        HStack {
                            Metric(value: fmt(e.socketMessagesPerSecond), label: "socket msgs / s")
                            Metric(value: fmt(e.ingressBytesPerSecond / 1_000), label: "kB / s ingress")
                        }
                        Text("A 1 Hz publisher: \(fmt(e.naiveCopiesPerSecond)) copies / s — \(fmt(e.naiveCopiesPerSecond / max(e.copiesPerSecond, 0.001)))× more.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Card(title: "Background pushes (APNs) per hour") {
                        HStack {
                            Metric(value: fmt(e.pushesPerHourUnbudgeted), label: "every copy pushed")
                            Metric(value: fmt(e.pushesPerHourBudgeted), label: "with budget (1 / \(Int(model.pushRefill.seconds / 60)) min)")
                        }
                        Text("Coalescing means a budget-delayed push carries the newest point, not a backlog.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Card(title: "Storage (latest copy only)") {
                        Metric(value: "\(e.storedBytes / 1_000) kB", label: "for 3,000 (share, viewer) pairs")
                        Text("Copy size \(bytes) bytes, measured from the scenario's real sealed copy. Assumes a commuting-hour mix: 55 % parked, 20 % walking, 5 % cycling, 20 % driving; 30 % of viewers in the foreground.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Capacity")
        }
    }

    private func fmt(_ d: Double) -> String {
        d >= 100 ? String(Saturating.int(d.rounded())) : String(format: "%.1f", d)
    }
}

// MARK: - Gate

struct GateTab: View {
    let manifest: CapabilityManifest
    @State private var declaredSharedLocation = false

    var body: some View {
        let drift = AgeRatingGate.check(manifest: manifest,
                                        declaration: AgeRatingDeclaration(sharedLocation: declaredSharedLocation))
        let withoutCapability = runtimeRefusal()
        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Card(title: "Capability manifest (compiled into the app)") {
                        Text(manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                            .font(.callout.monospaced())
                    }
                    Card(title: "App Store Connect · Shared Location") {
                        Toggle("Declared \"Yes\"", isOn: $declaredSharedLocation)
                        if drift.isEmpty {
                            Label("Gate passes: code and declaration agree", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            ForEach(drift, id: \.self) { d in
                                Label(d.message, systemImage: d.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(d.isBlocking ? .red : .orange).font(.callout)
                            }
                        }
                    }
                    Card(title: "Runtime side of the same rule") {
                        Text("A SharerSession built from a manifest without liveLocationSharing: \(withoutCapability)")
                            .font(.callout)
                        Text("Required for all apps by 12 Jan 2027 (Apple, 16 Nov 2026).").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Age rating")
        }
    }

    private func runtimeRefusal() -> String {
        let relay = LocationRelay()
        do {
            _ = try SharerSession(shareID: ShareID("x"), manifest: CapabilityManifest(capabilities: [.locationForAppFeatures]),
                                  sealer: PerViewerSealer(shareID: ShareID("x")), uplink: relay,
                                  clock: SystemClock(), presenceTTL: .seconds(120))
            return "started (gate is broken)"
        } catch {
            return "refused (\(error))"
        }
    }
}
