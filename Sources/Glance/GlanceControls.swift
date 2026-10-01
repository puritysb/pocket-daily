import SwiftUI

/// Weather and Calendar are separate sources even when Home displays them in
/// one panel. Neither control changes the reader's layout or requests access
/// until the user explicitly chooses it.
struct WeatherControls: View {
    @ObservedObject var settings: GlanceSettings
    @ObservedObject var model: PocketModel
    @State private var cityQuery = ""
    @State private var editingCity = false
    @State private var finding = false
    @State private var findError: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isDemoMode {
                Label("Seoul · example forecast", systemImage: "location.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let place = settings.place, !editingCity {
                HStack {
                    Label(place.name, systemImage: "location.circle")
                        .accessibilityIdentifier("glance-city")
                    Spacer()
                    Button("Change") { cityQuery = place.name; editingCity = true }
                        .buttonStyle(.borderless).font(.caption)
                }
                Text(weatherStatus).font(.caption).foregroundStyle(settings.weatherError == nil ? Color.secondary : .orange)
            } else {
                HStack(spacing: 8) {
                    TextField("City for weather", text: $cityQuery)
                        .textFieldStyle(.roundedBorder).onSubmit(find)
                        .accessibilityIdentifier("glance-city-field")
                    if finding {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { work?.cancel() }
                            .accessibilityIdentifier("glance-city-cancel")
                    } else {
                        Button("Set", action: find)
                            .disabled(cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("glance-city-set")
                        if editingCity { Button("Cancel") { editingCity = false; findError = nil } }
                    }
                }
                if let findError { Text(findError).font(.caption).foregroundStyle(.red) }
                Text("Choose a city. Your current location is not used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WeatherSourceCredit(loadMark: !model.isDemoMode && settings.place != nil)
        }
        .onDisappear { work?.cancel() }
    }

    private var weatherStatus: String {
        if settings.isRefreshing { return "Updating forecast…" }
        if let error = settings.weatherError { return error }
        if let weather = settings.weather { return "Updated \(weather.fetched.formatted(date: .omitted, time: .shortened))" }
        return "Not updated yet"
    }

    private func find() {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isDemoMode, !query.isEmpty, !finding else { return }
        finding = true
        findError = nil
        work = Task {
            defer { finding = false; work = nil }
            do {
                let place = try await WeatherSource.place(named: query)
                try Task.checkCancellation()
                settings.setPlace(place)
                editingCity = false
                model.refreshGlance(force: true)
            } catch {
                if !Task.isCancelled { findError = error.localizedDescription }
            }
        }
    }
}

/// Keep the official Weather mark and the legal link together next to the
/// weather source. The API supplies the mark; never substitute the Weather app
/// icon. Text and the public legal link remain available before setup/offline.
private struct WeatherSourceCredit: View {
    let loadMark: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: (mark: URL, markDark: URL, legal: URL)?

    var body: some View {
        HStack(spacing: 10) {
            if let attribution {
                AsyncImage(url: colorScheme == .dark ? attribution.markDark : attribution.mark) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Text("Apple Weather").font(.caption) }
                .frame(width: 92, height: 18)
                .accessibilityLabel("Apple Weather")
            } else {
                Text("Apple Weather").font(.caption)
            }
            if let legal = attribution?.legal ?? URL(string: "https://developer.apple.com/weatherkit/data-source-attribution/") {
                Link("Data sources", destination: legal).font(.caption)
                    .accessibilityIdentifier("weather-data-sources")
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("weather-source-credit")
        .task(id: loadMark) {
            guard loadMark else { return }
            attribution = await WeatherSource.attribution()
        }
    }
}

struct CalendarControls: View {
    @ObservedObject var settings: GlanceSettings
    @ObservedObject var model: PocketModel
    @State private var note: String?
    @State private var requestingAccess = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isDemoMode {
                Text("Example events · your calendars are not accessed")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if settings.includeEvents {
                    HStack {
                        Label("Calendar connected", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("Disconnect Calendar") { setEvents(false) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Calendar options")
                    }
                } else {
                    Button("Connect Calendar", systemImage: "calendar.badge.plus") { setEvents(true) }
                        .disabled(requestingAccess)
                        .accessibilityIdentifier("glance-events")
                }
                Text("Today’s events are shared only with your connected reader.")
                    .font(.caption).foregroundStyle(.secondary)
                if requestingAccess { ProgressView("Waiting for Calendar access…").font(.caption) }
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
        }
        .onDisappear { work?.cancel() }
    }

    private func setEvents(_ on: Bool) {
        guard !model.isDemoMode, !requestingAccess else { return }
        note = nil
        guard on else {
            settings.setIncludeEvents(false)
            model.pushGlance()
            return
        }
        requestingAccess = true
        work = Task {
            defer { requestingAccess = false; work = nil }
            var granted = CalendarSource.isAuthorized
            if !granted, !CalendarSource.isDenied { granted = await CalendarSource.requestAccess() }
            guard !Task.isCancelled else { return }
            if granted {
                settings.setIncludeEvents(true)
                model.pushGlance()
            } else {
                note = "Calendar access is off. Allow Pocket Daily in Settings → Privacy & Security → Calendars."
            }
        }
    }
}

/// One delivery status for the panel's sources, outside their individual controls.
struct GlanceDeliveryStatus: View {
    @ObservedObject var settings: GlanceSettings
    @ObservedObject var model: PocketModel

    var body: some View {
        if model.readerStatus != nil, !model.isDemoMode, !model.canSendGlance {
            Label("Weather and events need firmware \(FirmwareGuidance.minimumRecommended) or later. Open Reader → Connection to update.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("glance-unsupported")
        } else if model.canSendGlance, settings.isConfigured {
            HStack {
                Group {
                    if let error = model.glanceError { Text("Not sent · \(error)").foregroundStyle(.orange) }
                    else if let sent = model.glanceSentAt {
                        Text("Sent at \(sent.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    } else { Text("Updates when your reader connects").foregroundStyle(.secondary) }
                }.font(.caption)
                Spacer()
                if model.glanceError != nil {
                    Button("Retry") { model.refreshGlance(force: true) }
                        .buttonStyle(.borderless).font(.caption).disabled(model.isWorking)
                        .accessibilityIdentifier("glance-send")
                }
            }
        }
    }
}
