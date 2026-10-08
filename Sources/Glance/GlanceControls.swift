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
                model.refreshGlance(force: true, send: false)
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
        HStack(spacing: 8) {
            if let attribution {
                AsyncImage(url: colorScheme == .dark ? attribution.markDark : attribution.mark) { image in
                    image.resizable().scaledToFit()
                        .frame(width: 82, height: 16).clipped()
                } placeholder: { Text("Apple Weather").font(.caption) }
                .frame(width: 82, height: 16).clipped()
                .accessibilityLabel("Apple Weather")
            } else {
                Text("Apple Weather").font(.caption)
            }
            if let legal = attribution?.legal ?? URL(string: "https://developer.apple.com/weatherkit/data-source-attribution/") {
                Link("Data sources", destination: legal).font(.caption2)
                    .accessibilityIdentifier("weather-data-sources")
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .fixedSize(horizontal: false, vertical: true)
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
    @State private var calendars: [CalendarSource.Choice] = []
    @State private var choosingCalendars = false
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
                if settings.includeEvents {
                    Button(settings.selectedCalendarIDs == nil ? "Choose calendars · All" : "Choose calendars · \(settings.selectedCalendarIDs?.count ?? 0) selected") {
                        choosingCalendars.toggle()
                        reloadCalendars()
                    }
                    .accessibilityIdentifier("glance-choose-calendars")
                    if choosingCalendars {
                        Toggle("All calendars", isOn: Binding(get: { settings.selectedCalendarIDs == nil }, set: {
                            settings.setSelectedCalendarIDs($0 ? nil : [])
                        }))
                        .accessibilityIdentifier("glance-all-calendars")
                        if settings.selectedCalendarIDs != nil {
                            ForEach(calendars) { calendar in
                                Toggle(calendar.title + " · " + calendar.source, isOn: Binding(get: {
                                    settings.selectedCalendarIDs?.contains(calendar.id) == true
                                }, set: { selected in
                                    var ids = settings.selectedCalendarIDs ?? []
                                    if selected { ids.append(calendar.id) } else { ids.removeAll { $0 == calendar.id } }
                                    settings.setSelectedCalendarIDs(ids)
                                }))
                            }
                            let missing = Set(settings.selectedCalendarIDs ?? []).subtracting(calendars.map(\.id)).count
                            if missing > 0 { Text("\(missing) selected calendars unavailable. Selection kept.").font(.caption).foregroundStyle(.orange) }
                            if settings.selectedCalendarIDs?.isEmpty == true { Text("No calendar events selected").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if CalendarSource.isDenied || (settings.includeEvents && !CalendarSource.isAuthorized) {
                    Button("Check Calendar access") { setEvents(true) }
                        .disabled(requestingAccess)
                        .accessibilityIdentifier("glance-check-calendar-access")
                    #if os(macOS)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        Link("Open Calendar privacy settings", destination: url)
                    }
                    #else
                    if let url = URL(string: "app-settings:") { Link("Open Settings", destination: url) }
                    #endif
                }
                if requestingAccess { ProgressView("Waiting for Calendar access…").font(.caption) }
                if let note { Text(note).font(.caption).foregroundStyle(.orange) }
            }
        }
        .onDisappear { work?.cancel() }
    }

    private func reloadCalendars() {
        guard !model.isDemoMode else { return }
        calendars = CalendarSource.availableCalendars()
    }

    private func setEvents(_ on: Bool) {
        guard !model.isDemoMode, !requestingAccess else { return }
        note = nil
        guard on else {
            settings.setIncludeEvents(false)
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
                reloadCalendars()
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
            Label("Weather and events need firmware \(FirmwareGuidance.minimumRecommended) or later. Open My Reader → Reader options → Manage reader to update.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .accessibilityIdentifier("glance-unsupported")
        } else if settings.hasUnappliedSourceChanges {
            Text("Content changes saved locally · Apply content to Reader")
                .font(.caption).foregroundStyle(.secondary)
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
