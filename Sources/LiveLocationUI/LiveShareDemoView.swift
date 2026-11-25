import SwiftUI
import MapKit
import LiveLocation

/// Root view of the demo: four tabs, each backed by real library calls.
public struct LiveShareDemoView: View {
    public enum Tab: String, CaseIterable, Sendable { case sharer, viewers, capacity, gate }

    @State private var model: ScenarioModel
    @State private var selection: Tab

    /// - Parameters:
    ///   - manifest: the app's capability manifest (the demo app loads it from its bundle).
    ///   - declaration: the app's exported App Store Connect age-rating answer (also from the bundle).
    public init(manifest: CapabilityManifest, declaration: AgeRatingDeclaration, initialTab: Tab = .sharer) {
        _model = State(initialValue: ScenarioModel(manifest: manifest, declaration: declaration))
        _selection = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selection) {
            SharerTab(model: model).tabItem { Label("Sharer", systemImage: "location.fill") }.tag(Tab.sharer)
            ViewersTab(model: model).tabItem { Label("Viewers", systemImage: "person.3.fill") }.tag(Tab.viewers)
            CapacityTab(model: model).tabItem { Label("Capacity", systemImage: "gauge.with.dots.needle.67percent") }.tag(Tab.capacity)
            GateTab(model: model).tabItem { Label("Age rating", systemImage: "checkmark.shield") }.tag(Tab.gate)
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

extension View {
    /// Compact titles on iOS so each tab's content fits above the floating tab bar.
    func compactTitle(_ title: String) -> some View {
        #if os(iOS)
        return navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        return navigationTitle(title)
        #endif
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
                                Metric(value: "\(c.uploaded)", label: "points sent")
                                Metric(value: "\(c.heartbeats)", label: "heartbeats")
                            }
                            Text("Points reached the relay as one sealed copy per viewer. A naive 1 Hz publisher would have sent \(ScenarioModel.scenarioMinutes * 60).")
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
                                Text("Heartbeat every \(cad.heartbeatInterval.value / 1_000)s · presence TTL \(model.presenceTTL.value / 1_000)s")
                                    .font(.subheadline)
                            }
                        }
                        Card(title: "Timeline") {
                            DisclosureGroup("\(model.timeline.count) events") {
                                ForEach(model.timeline) { e in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(e.minute).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(e.text).font(.caption)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .padding()
                .padding(.bottom, 72)   // keep the last card clear of the floating tab bar
            }
            .compactTitle("Sharing")
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
                .padding(.bottom, 72)   // keep the last card clear of the floating tab bar
            }
            .compactTitle("Viewers")
        }
    }

    private var map: some View {
        // Viewers who last decrypted the same point share one marker ("Alice, Bob see"), so a pin is never
        // hidden underneath another.
        var groups: [(names: [String], coordinate: CLLocationCoordinate2D)] = []
        for v in model.viewers {
            guard let lat = v.latitude, let lon = v.longitude else { continue }
            if let i = groups.firstIndex(where: { $0.coordinate.latitude == lat && $0.coordinate.longitude == lon }) {
                groups[i].names.append(v.name)
            } else {
                groups.append(([v.name], CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            }
        }
        return Map {
            MapPolyline(coordinates: model.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                .stroke(.blue.opacity(0.5), lineWidth: 4)
            ForEach(groups.indices, id: \.self) { i in
                Marker("\(groups[i].names.joined(separator: " & ")) \(groups[i].names.count == 1 ? "sees" : "see")", coordinate: groups[i].coordinate)
                    .tint(i == 0 ? .green : .orange)
            }
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func viewerCard(_ v: ViewerRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color(v.freshness)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(v.name) · \(v.freshness.label)").font(.headline)
                Text("\(v.channel.rawValue) · \(v.received) decrypted\(v.rejected > 0 ? " · \(v.rejected) rejected" : "")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.finished && model.copyBytes > 0 {
                        content(FanoutLoadModel.estimate(.reference(copyBytes: model.copyBytes, pushRefill: model.pushRefill)))
                    } else {
                        RunningPlaceholder(running: model.isRunning)
                    }
                }
                .padding()
                .padding(.bottom, 72)
            }
            .compactTitle("Capacity")
        }
    }

    @ViewBuilder
    private func content(_ e: LoadEstimate) -> some View {
        let refillMinutes = model.pushRefill.value / 60_000
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
                Metric(value: fmt(e.pushesPerHourBudgeted), label: "with budget (1 / \(refillMinutes) min)")
            }
            Text("Coalescing means a budget-delayed push carries the newest point, not a backlog.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Card(title: "Storage (latest copy only)") {
            Metric(value: "\((e.storedBytes / 1_000).formatted(.number.locale(Self.numbers))) kB", label: "for 3,000 (share, viewer) pairs")
            Text("Copy size \(model.copyBytes) bytes, measured from the scenario's real sealed copy (plaintext padded to a fixed size). Assumes a commuting-hour mix: 55 % parked, 20 % walking, 5 % cycling, 20 % driving; 30 % of viewers in the foreground.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Fixed grouping (1,234,567) whatever the device region, so the numbers match the README.
    static let numbers = Locale(identifier: "en_US_POSIX")

    private func fmt(_ d: Double) -> String {
        d >= 100 ? Saturating.int(d.rounded()).formatted(.number.locale(Self.numbers)) : String(format: "%.1f", d)
    }
}

// MARK: - Gate

struct GateTab: View {
    let model: ScenarioModel
    @State private var simulateDrift = false

    var body: some View {
        let declared = AgeRatingDeclaration(sharedLocation: simulateDrift ? !model.declaration.sharedLocation
                                                                            : model.declaration.sharedLocation)
        let drift = AgeRatingGate.check(manifest: model.manifest, declaration: declared)
        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Card(title: "Capability manifest (bundled config)") {
                        Text(model.manifest.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                            .font(.callout.monospaced())
                    }
                    Card(title: "App Store Connect · Shared Location") {
                        Text("Declared: \(declared.sharedLocation ? "Yes" : "No")").font(.headline)
                        Toggle("Simulate a drifted answer", isOn: $simulateDrift)
                        if drift.isEmpty {
                            Label("Gate passes: code and declaration agree", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            ForEach(drift, id: \.self) { d in
                                Label(d.message, systemImage: d.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(d.isBlocking ? .red : .orange).font(.callout)
                            }
                        }
                        Text("The same check runs in the demo repo's CI against the same two JSON files.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Card(title: "Runtime side of the same rule") {
                        Text("A SharerSession built from a manifest without liveLocationSharing: \(model.refusal.isEmpty ? "…" : model.refusal)")
                            .font(.callout)
                        Text("Required for all apps by 12 Jan 2027 (Apple, 16 Nov 2026). In Brazil, Shared Location means an A16 rating.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .padding(.bottom, 72)
            }
            .compactTitle("Age rating")
        }
    }
}
