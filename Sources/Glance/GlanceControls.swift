import SwiftUI

/// Where the reader's weather and events come from: a city the user names
/// (Apple Weather) and, if turned on, today's events from this device's
/// calendars. Both are sent to a connected reader automatically.
struct GlanceControls: View {
    @ObservedObject var settings: GlanceSettings
    @ObservedObject var model: PocketModel
    @State private var cityQuery = ""
    @State private var finding = false
    @State private var findError: String?
    @State private var calendarNote: String?
    @State private var attribution: (mark: URL, markDark: URL, legal: URL)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = settings.place {
                HStack {
                    Label(place.name, systemImage: "location.circle")
                        .accessibilityIdentifier("glance-city")
                    Spacer()
                    Button("Change") { settings.setPlace(nil); cityQuery = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Text(weatherStatus).font(.caption2).foregroundStyle(settings.weatherError == nil ? Color.secondary : .orange)
                attributionView
            } else {
                HStack {
                    TextField("City for weather", text: $cityQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(find)
                        .accessibilityIdentifier("glance-city-field")
                    Button(finding ? "Finding…" : "Set", action: find)
                        .disabled(finding || cityQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("glance-city-set")
                }
                if let findError { Text(findError).font(.caption).foregroundStyle(.red) }
            }
            Toggle("Today's events from Calendar", isOn: Binding(get: { settings.includeEvents }, set: setEvents))
                .accessibilityIdentifier("glance-events")
            if let calendarNote { Text(calendarNote).font(.caption).foregroundStyle(.orange) }
            deliveryStatus
        }
        .task(id: settings.place) {
            guard settings.place != nil else { return }
            attribution = await WeatherSource.attribution()
        }
    }

    /// Weather and events go to the reader on their own (on connection, after
    /// a refresh, with Apply); this says what happened and offers a retry.
    @ViewBuilder private var deliveryStatus: some View {
        if model.readerStatus != nil, !model.isDemoMode, !model.canSendGlance {
            Label("Weather and events need reader firmware \(FirmwareGuidance.minimumRecommended) or later. Use Update reader in the Reader panel.", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .accessibilityIdentifier("glance-unsupported")
        } else if model.canSendGlance, settings.isConfigured {
            HStack {
                Group {
                    if let error = model.glanceError {
                        Text("Not sent · \(error)").foregroundStyle(.orange)
                    } else if let sent = model.glanceSentAt {
                        Text("Sent to the reader at \(sent.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Sent automatically when the reader connects").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                Spacer()
                // Delivery is automatic (and part of Apply); a manual send is
                // only offered to recover from a failed one.
                if model.glanceError != nil {
                    Button("Retry") { model.refreshGlance(force: true) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("glance-send")
                }
            }
        }
    }

    private var weatherStatus: String {
        if settings.isRefreshing { return "Updating Apple Weather…" }
        if let error = settings.weatherError { return error }
        if let weather = settings.weather {
            return "Updated \(weather.fetched.formatted(date: .omitted, time: .shortened))"
        }
        return "Not updated yet"
    }

    /// Apple requires its Weather mark and a legal link wherever its data is used.
    @ViewBuilder private var attributionView: some View {
        if let attribution {
            HStack(spacing: 8) {
                AsyncImage(url: colorScheme == .dark ? attribution.markDark : attribution.mark) { image in
                    image.resizable().scaledToFit()
                } placeholder: { Text("Apple Weather").font(.caption2) }
                .frame(height: 12)
                Link("Data sources", destination: attribution.legal)
                    .font(.caption2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func find() {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !finding else { return }
        finding = true
        findError = nil
        Task {
            defer { finding = false }
            do {
                settings.setPlace(try await WeatherSource.place(named: query))
                model.refreshGlance(force: true)
            } catch { findError = error.localizedDescription }
        }
    }

    private func setEvents(_ on: Bool) {
        calendarNote = nil
        guard on else {
            settings.setIncludeEvents(false)
            model.pushGlance()
            return
        }
        Task {
            var granted = CalendarSource.isAuthorized
            if !granted, !CalendarSource.isDenied { granted = await CalendarSource.requestAccess() }
            if granted {
                settings.setIncludeEvents(true)
                model.pushGlance()
            } else {
                calendarNote = "Calendar access is off. Turn it on for Pocket Daily in System Settings › Privacy & Security › Calendars."
            }
        }
    }
}
