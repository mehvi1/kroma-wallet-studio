import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct ConnectedDevice: Decodable, Identifiable {
    var id: String { udid }
    let udid: String
    let name: String
    let version: String
    let product: String
    let connected: Bool
    let airlift_compatible: Bool?
}

private struct DeviceList: Decodable {
    let connected: Bool
    let devices: [ConnectedDevice]?
    let selected_udid: String?
    let device: ConnectedDevice?
    let error: String?
}

private struct SavedCardList: Decodable {
    let ok: Bool
    let cards: [String]
}

private struct BackendResult: Decodable {
    let ok: Bool?
    let path: String?
    let error: String?
}

private struct SkinPreset: Identifiable {
    let id: String
    let name: String
    let colors: [NSColor]

    static let all: [SkinPreset] = [
        .init(id: "lagoon", name: "Lagoon", colors: [NSColor(rgb: 0x0B3954), NSColor(rgb: 0x087E8B), NSColor(rgb: 0xBFD7EA)]),
        .init(id: "dune", name: "Dune", colors: [NSColor(rgb: 0x3D2C20), NSColor(rgb: 0xB98249), NSColor(rgb: 0xE9CFA8)]),
        .init(id: "orchid", name: "Orchid", colors: [NSColor(rgb: 0x27104E), NSColor(rgb: 0x8A3FFC), NSColor(rgb: 0xE3B8FF)]),
        .init(id: "pine", name: "Pine", colors: [NSColor(rgb: 0x0B2925), NSColor(rgb: 0x277A60), NSColor(rgb: 0xB6D7B9)]),
        .init(id: "solar", name: "Solar", colors: [NSColor(rgb: 0x6B351B), NSColor(rgb: 0xF39A31), NSColor(rgb: 0xFFE39A)]),
        .init(id: "ember", name: "Ember", colors: [NSColor(rgb: 0x341923), NSColor(rgb: 0xC44750), NSColor(rgb: 0xFFB18D)]),
        .init(id: "glacier", name: "Glacier", colors: [NSColor(rgb: 0x132E4A), NSColor(rgb: 0x4B9DC7), NSColor(rgb: 0xC5F1F2)]),
        .init(id: "noir", name: "Noir", colors: [NSColor(rgb: 0x10151E), NSColor(rgb: 0x424D60), NSColor(rgb: 0xADB8C8)])
    ]

    func writePNG(overwrite: Bool = false) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = appSupport.appendingPathComponent("Kroma/SkinPresets", isDirectory: true)
        let output = folder.appendingPathComponent("\(id).png")
        if !overwrite, FileManager.default.fileExists(atPath: output.path) { return output }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let size = NSSize(width: 1536, height: 969)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            let bounds = NSRect(origin: .zero, size: size)
            NSGradient(colors: colors)?.draw(in: bounds, angle: -28)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 940, y: 480, width: 820, height: 820)).fill()
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: -300, y: -480, width: 1060, height: 1060)).fill()
            NSColor.white.withAlphaComponent(0.2).setStroke()
            let arc = NSBezierPath()
            arc.lineWidth = 4
            arc.move(to: NSPoint(x: 30, y: 250))
            arc.curve(to: NSPoint(x: 1490, y: 730), controlPoint1: NSPoint(x: 470, y: 660), controlPoint2: NSPoint(x: 920, y: 170))
            arc.stroke()
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
            try data.write(to: output, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return output
        } catch { return nil }
    }
}

private struct LibrarySkin: Identifiable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
private final class StudioModel: ObservableObject {
    @Published var devices: [ConnectedDevice] = []
    @Published var selectedDeviceID: String?
    @Published var cards: [String] = []
    @Published var selectedCardID: String?
    @Published var selectedImageURL: URL?
    @Published var selectedPresetID: String?
    @Published var customStart = Color(red: 0.18, green: 0.38, blue: 0.76)
    @Published var customMiddle = Color(red: 0.50, green: 0.30, blue: 0.78)
    @Published var customEnd = Color(red: 0.96, green: 0.52, blue: 0.35)
    @Published var librarySkins: [LibrarySkin] = []
    @Published var membershipActive = false
    @Published var membershipBusy = false
    @Published var activationCode = ""
    @Published var membershipMessage = "Check your Kroma membership to open the skin library."
    @Published var membershipExpiresAt: String?
    @Published var skinSearch = ""
    @Published var isScanning = false
    @Published var isApplying = false
    @Published var showApplyConfirmation = false
    @Published var status = "Connect and trust your iPhone over USB to begin."
    @Published var error: String?
    @Published var progress: Double = 0

    private var scanProcess: Process?
    private let membershipClient = NativeMembershipClient()
    private var device: ConnectedDevice? { devices.first { $0.id == selectedDeviceID } }
    var isCompatible: Bool { device?.airlift_compatible == true }
    private let defaults = UserDefaults.standard

    init() {
        guard let values = defaults.array(forKey: "kroma.customPalette") as? [Int], values.count == 3 else { return }
        customStart = Color(nsColor: NSColor(rgb: UInt32(values[0])))
        customMiddle = Color(nsColor: NSColor(rgb: UInt32(values[1])))
        customEnd = Color(nsColor: NSColor(rgb: UInt32(values[2])))
    }

    private func loadSkinLibrary(from downloaded: [(NativeSkin, URL)]) {
        let sorted = downloaded.sorted { $0.0.id.localizedStandardCompare($1.0.id) == .orderedAscending }
        librarySkins = sorted.map { skin, url in LibrarySkin(id: skin.id, name: skin.name, url: url) }
        restoreImageForSelection()
    }

    private func clearLockedLibrarySelection() {
        if let path = defaults.string(forKey: "kroma.skin.\(selectedCardID ?? "")"),
           path.contains("/Kroma/SkinLibrary/") {
            defaults.removeObject(forKey: "kroma.skin.\(selectedCardID ?? "")")
            selectedImageURL = nil
            selectedPresetID = nil
        }
    }

    func refreshMembership() {
        guard !membershipBusy else { return }
        membershipBusy = true
        Task {
            defer { membershipBusy = false }
            do {
                let membership = try await membershipClient.membership()
                guard membership.active else {
                    membershipActive = false
                    membershipExpiresAt = nil
                    membershipClient.removeCachedLibrary()
                    librarySkins = []
                    clearLockedLibrarySelection()
                    membershipMessage = membershipClient.isConfigured
                        ? "No active membership on this Mac. Redeem a Kroma code to open all 211 skins."
                        : "Kroma membership is not configured for this build. The 211 paid skins are not included in the app."
                    return
                }
                membershipActive = true
                membershipExpiresAt = membership.expiresAt
                membershipMessage = "Membership active. Loading your private skin library…"
                let downloaded = try await membershipClient.downloadLibrary()
                loadSkinLibrary(from: downloaded)
                membershipMessage = "Membership active · \(downloaded.count) skins ready."
            } catch {
                membershipActive = false
                librarySkins = []
                clearLockedLibrarySelection()
                membershipMessage = error.localizedDescription
            }
        }
    }

    func redeemActivationCode() {
        guard !membershipBusy else { return }
        let code = activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { membershipMessage = "Enter the activation code from Kroma admin."; return }
        membershipBusy = true
        membershipMessage = "Checking activation code…"
        Task {
            defer { membershipBusy = false }
            do {
                try await membershipClient.activate(code: code)
                activationCode = ""
                membershipMessage = "Code accepted. Loading your membership…"
                let membership = try await membershipClient.membership()
                guard membership.active else { throw NativeMembershipError.membershipRequired }
                membershipActive = true
                membershipExpiresAt = membership.expiresAt
                let downloaded = try await membershipClient.downloadLibrary()
                loadSkinLibrary(from: downloaded)
                membershipMessage = "Membership active · \(downloaded.count) skins ready."
            } catch {
                membershipActive = false
                librarySkins = []
                membershipMessage = error.localizedDescription
            }
        }
    }

    var filteredLibrarySkins: [LibrarySkin] {
        let query = skinSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return librarySkins }
        return librarySkins.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var deviceLabel: String {
        guard let device else { return "No iPhone connected" }
        return "\(device.name) · iOS \(device.version)"
    }

    var applyReady: Bool {
        selectedCardID != nil && selectedImageURL != nil && isCompatible && !isApplying
            && (!isPremiumImage(selectedImageURL) || membershipActive)
    }

    private func isPremiumImage(_ url: URL?) -> Bool { url?.path.contains("/Kroma/SkinLibrary/") == true }

    func refresh() {
        Task.detached { [weak self] in
            guard let result = try? await Self.runBackend("--devices", arguments: []) else {
                await self?.setStatus("Device check failed. Reconnect and try again.")
                return
            }
            await self?.acceptDeviceResult(result)
        }
    }

    private func acceptDeviceResult(_ data: Data) {
        let response = try? JSONDecoder().decode(DeviceList.self, from: data)
        devices = response?.devices ?? []
        selectedDeviceID = response?.selected_udid ?? response?.device?.udid
        if let device {
            status = device.airlift_compatible == true
                ? "Connected. Choose a card, then preview a skin."
                : "Connected, but the current iOS build did not pass the compatibility check."
        } else {
            status = "No trusted iPhone found. Connect it by USB and unlock it."
        }
        loadCards()
    }

    private func setStatus(_ value: String) { status = value }

    func loadCards() {
        Task.detached { [weak self] in
            guard let data = try? await Self.runBackend("--cards", arguments: []),
                  let response = try? JSONDecoder().decode(SavedCardList.self, from: data) else { return }
            await self?.acceptSavedCards(response.cards)
        }
    }

    private func acceptSavedCards(_ values: [String]) {
        let hadSelection = selectedCardID != nil
        cards = values
        if selectedCardID == nil { selectedCardID = values.first }
        if !hadSelection, let card = selectedCardID,
           defaults.string(forKey: "kroma.skin.\(card)") == nil,
           let selectedImageURL {
            defaults.set(selectedImageURL.path, forKey: "kroma.skin.\(card)")
            return
        }
        restoreImageForSelection()
    }

    func chooseCard(_ id: String) {
        selectedCardID = id
        restoreImageForSelection()
    }

    func choosePreset(_ preset: SkinPreset) {
        guard let url = preset.writePNG() else { error = "Could not create this skin preset."; return }
        assignImage(url, presetID: preset.id)
    }

    func chooseLibrarySkin(_ skin: LibrarySkin) {
        guard membershipActive else { membershipMessage = "Redeem an active Kroma membership to use the private skin library."; return }
        assignImage(skin.url, presetID: "library:\(skin.id)")
    }

    func createCustomSkin() {
        let preset = SkinPreset(
            id: "custom-palette",
            name: "Custom Mix",
            colors: [NSColor(customStart), NSColor(customMiddle), NSColor(customEnd)]
        )
        defaults.set([customStart, customMiddle, customEnd].map { color -> Int in
            let value = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
            let red = Int((value.redComponent * 255).rounded())
            let green = Int((value.greenComponent * 255).rounded())
            let blue = Int((value.blueComponent * 255).rounded())
            return (red << 16) | (green << 8) | blue
        }, forKey: "kroma.customPalette")
        guard let url = preset.writePNG(overwrite: true) else {
            error = "Could not save your custom skin. Check Kroma's local storage permissions."
            return
        }
        assignImage(url, presetID: preset.id)
        status = "Custom skin saved on this Mac and selected for the current card."
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the artwork to preview on this Wallet card."
        if panel.runModal() == .OK, let url = panel.url { assignImage(url) }
    }

    private func assignImage(_ url: URL, presetID: String? = nil) {
        selectedImageURL = url
        selectedPresetID = presetID
        if let card = selectedCardID {
            defaults.set(url.path, forKey: "kroma.skin.\(card)")
            status = "Skin ready for preview. Apply will only target the selected card."
        } else {
            status = "Previewing this skin. Connect and scan your iPhone when you are ready to apply it."
        }
    }

    private func restoreImageForSelection() {
        guard let card = selectedCardID,
              let path = defaults.string(forKey: "kroma.skin.\(card)") else { selectedImageURL = nil; selectedPresetID = nil; return }
        let url = URL(fileURLWithPath: path)
        if isPremiumImage(url), !membershipActive { selectedImageURL = nil; selectedPresetID = nil; return }
        selectedImageURL = FileManager.default.fileExists(atPath: path) ? url : nil
        let presetID = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        selectedPresetID = presetID == "custom-palette" || SkinPreset.all.contains(where: { $0.id == presetID }) ? presetID : nil
    }

    func startScan() {
        guard !isScanning, let deviceID = selectedDeviceID else { status = "Connect a trusted iPhone before scanning."; return }
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("bin/device_helper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { error = "The bundled device helper is missing."; return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = ["syslog", deviceID]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            scanProcess = process
            isScanning = true
            status = "Open Wallet on your iPhone and tap the card you want to customize."
            Task.detached { [weak self] in
                let handle = pipe.fileHandleForReading
                while process.isRunning {
                    let data = handle.availableData
                    if data.isEmpty { try? await Task.sleep(for: .milliseconds(40)); continue }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    let matches = text.components(separatedBy: .newlines).flatMap { KromaCardScanner.cardIDs(in: $0) }
                    if !matches.isEmpty { await self?.recordCards(matches) }
                }
                await self?.finishScan()
            }
        } catch { self.error = "Could not start the Wallet scanner: \(error.localizedDescription)" }
    }

    func stopScan() {
        scanProcess?.terminate()
        finishScan()
    }

    private func finishScan() {
        scanProcess = nil
        isScanning = false
        if !cards.isEmpty { persistCards(); status = "Scan finished. Choose one card and set its skin." }
    }

    private func recordCards(_ found: [String]) {
        let oldSelection = selectedCardID
        let pendingPreview = selectedImageURL
        cards = Array(NSOrderedSet(array: cards + found)) as? [String] ?? cards
        if selectedCardID == nil { selectedCardID = found.first }
        persistCards()
        if selectedCardID != oldSelection {
            if oldSelection == nil, let card = selectedCardID, let pendingPreview {
                defaults.set(pendingPreview.path, forKey: "kroma.skin.\(card)")
            } else {
                restoreImageForSelection()
            }
        }
        status = "Found \(found.count) Wallet card reference(s). Continue tapping cards or stop scanning."
    }

    private func persistCards() {
        guard let json = try? JSONSerialization.data(withJSONObject: cards),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        Task.detached { _ = try? await Self.runBackend("--save-cards", arguments: [jsonString]) }
    }

    func apply() {
        guard applyReady, let deviceID = selectedDeviceID, let card = selectedCardID, let image = selectedImageURL else { return }
        isApplying = true
        progress = 0.05
        status = "Applying skin to the selected Wallet card…"
        Task.detached { [weak self] in
            do {
                let prepared = FileManager.default.temporaryDirectory.appendingPathComponent("kroma-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: prepared) }
                _ = try await Self.runBackend("--prepare-image", arguments: [image.path, prepared.path])
                let result = try await Self.runBackend("--flash", arguments: [deviceID, card, prepared.path])
                let records = String(data: result, encoding: .utf8)?.components(separatedBy: .newlines) ?? []
                let finished = records.contains { $0.contains("\"type\": \"success\"") || $0.contains("Successfully updated") }
                await self?.finishApply(finished)
            } catch {
                await self?.failApply(error.localizedDescription)
            }
        }
    }

    private func finishApply(_ finished: Bool) {
        isApplying = false
        progress = finished ? 1 : 0
        status = finished ? "Applied. Close and reopen Wallet on the iPhone to refresh its artwork." : "The apply step did not report success. Check the connection and try again."
    }

    private func failApply(_ message: String) {
        isApplying = false
        progress = 0
        error = message
    }

    private static func runBackend(_ command: String, arguments: [String]) async throws -> Data {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("kroma_backend.py") else {
            throw NSError(domain: "Kroma", code: 1, userInfo: [NSLocalizedDescriptionKey: "Backend is missing from this build."])
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, command] + arguments
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "\(script.deletingLastPathComponent().path)/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]) { _, new in new }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Backend command failed."
            throw NSError(domain: "Kroma", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

@main
struct KromaApp: App {
    var body: some Scene {
        WindowGroup { StudioView().frame(minWidth: 1120, minHeight: 680) }
            .windowStyle(.hiddenTitleBar)
    }
}

private struct StudioView: View {
    @StateObject private var model = StudioModel()

    private let ink = Color(red: 0.055, green: 0.075, blue: 0.11)
    private let panel = Color(red: 0.09, green: 0.115, blue: 0.16)
    private let accent = Color(red: 0.97, green: 0.49, blue: 0.25)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                workspace
            }
            .background(ink)
        }
        .background(ink)
        .preferredColorScheme(.dark)
        .task { model.refreshMembership(); model.refresh() }
        .confirmationDialog("Apply this skin to the selected Wallet card?", isPresented: $model.showApplyConfirmation, titleVisibility: .visible) {
            Button("Apply Skin", role: .destructive) { model.apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes Wallet artwork on the connected iPhone using an iOS-version-dependent method. Keep a current iPhone backup. This app does not create a rollback backup.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 11) {
                KromaMark(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KROMA").font(.system(size: 15, weight: .black, design: .rounded)).tracking(2)
                    Text("WALLET SKIN STUDIO").font(.system(size: 8, weight: .bold)).tracking(1.3).foregroundStyle(.white.opacity(0.48))
                }
            }
            .padding(.top, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                Text("YOUR CARDS").font(.system(size: 9, weight: .bold)).tracking(1.6).foregroundStyle(.white.opacity(0.38))
                if model.cards.isEmpty {
                    Text("Cards you scan from Wallet will appear here.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(model.cards.enumerated()), id: \.element) { index, card in
                        Button { model.chooseCard(card) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "creditcard").foregroundStyle(model.selectedCardID == card ? accent : .white.opacity(0.5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wallet card \(index + 1)").font(.system(size: 12, weight: .medium))
                                    Text("ID ···\(card.suffix(5))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer(minLength: 0)
                                if model.selectedCardID == card { Circle().fill(accent).frame(width: 6, height: 6) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 10)
                            .background(model.selectedCardID == card ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 7)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("KROMA PLUS").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(accent)
                        Spacer()
                        if model.membershipActive { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    }
                    Text(model.membershipMessage)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                    if let expiry = model.membershipExpiresAt {
                        Text("Active until \(expiry.prefix(10))").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    }
                    TextField("Activation code", text: $model.activationCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                    Button { model.redeemActivationCode() } label: {
                        HStack { Spacer(); if model.membershipBusy { ProgressView().controlSize(.small) }; Text("Activate membership").font(.system(size: 10, weight: .semibold)); Spacer() }
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(ink)
                    .disabled(model.membershipBusy || model.activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Refresh membership") { model.refreshMembership() }
                        .buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.56))
                        .disabled(model.membershipBusy)
                }
                .padding(11)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Circle().fill(model.isCompatible ? Color.green : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                    Text(model.deviceLabel).font(.system(size: 10, weight: .medium)).lineLimit(2)
                }
                Button { model.refresh() } label: {
                    Label("Check connection", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.66))
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            Text("Kroma is an independent project.").font(.system(size: 9)).foregroundStyle(.white.opacity(0.34))
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
        .frame(width: 235)
        .background(Color(red: 0.075, green: 0.095, blue: 0.135))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make your Wallet feel like yours.")
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Choose one card, find a look, preview it, then apply.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Button { model.isScanning ? model.stopScan() : model.startScan() } label: {
                Label(model.isScanning ? "Stop scan" : "Scan Wallet", systemImage: model.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent).tint(model.isScanning ? Color.red.opacity(0.8) : accent).foregroundStyle(ink)
            .disabled(model.selectedDeviceID == nil || model.isApplying)
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
    }

    private var workspace: some View {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.42))
                    previewCard
                    if model.selectedCardID == nil {
                        VStack(alignment: .leading, spacing: 9) {
                            Label(model.isScanning ? "Listening for your card" : "Ready when you are", systemImage: "iphone.gen3.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                            Text(model.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.56)).fixedSize(horizontal: false, vertical: true)
                            if model.selectedDeviceID != nil {
                                Button { model.isScanning ? model.stopScan() : model.startScan() } label: {
                                    Label(model.isScanning ? "Stop scan" : "Scan Wallet", systemImage: model.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                                        .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                }
                                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(ink)
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.56)).fixedSize(horizontal: false, vertical: true)
                        if model.isApplying { ProgressView(value: model.progress).tint(accent) }
                        Button { model.showApplyConfirmation = true } label: {
                            HStack { Spacer(); if model.isApplying { ProgressView().controlSize(.small) }; Text(model.isApplying ? "Applying…" : "Apply to this card").font(.system(size: 12, weight: .bold)); Spacer() }
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(ink).disabled(!model.applyReady)
                        if !model.applyReady {
                            Text("Needs a skin and a compatible connected iPhone.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.36))
                        }
                    }
                }
                .frame(maxWidth: 390, alignment: .leading)

                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PICK A LOOK").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.42))
                            Text("8 originals · \(model.librarySkins.count) library skins · custom palettes")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.66))
                        }
                        Spacer()
                        Button { model.chooseImage() } label: { Label("Your image", systemImage: "photo.badge.plus").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.bordered).tint(.white.opacity(0.12))
                    }
                    HStack(spacing: 10) {
                        palettePicker("A", color: $model.customStart)
                        palettePicker("B", color: $model.customMiddle)
                        palettePicker("C", color: $model.customEnd)
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [model.customStart, model.customMiddle, model.customEnd], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 48, height: 28)
                            .accessibilityLabel("Live preview of your custom palette")
                        Button { model.createCustomSkin() } label: {
                            Label("Create skin", systemImage: "wand.and.stars")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(ink)
                    }
                    .padding(10)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    TextField("Search skins by name or ID", text: $model.skinSearch)
                        .textFieldStyle(.roundedBorder)
                    Text("\(model.filteredLibrarySkins.count) of \(model.librarySkins.count) library skins")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("KROMA ORIGINALS")
                                .font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.42))
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(SkinPreset.all) { preset in
                                    Button { model.choosePreset(preset) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            RoundedRectangle(cornerRadius: 11)
                                                .fill(LinearGradient(colors: preset.colors.map(Color.init(nsColor:)), startPoint: .topLeading, endPoint: .bottomTrailing))
                                                .frame(height: 72)
                                                .overlay(alignment: .topTrailing) {
                                                    Image(systemName: model.selectedPresetID == preset.id ? "checkmark.circle.fill" : "sparkle")
                                                        .font(.system(size: 15, weight: .semibold))
                                                        .foregroundStyle(.white.opacity(model.selectedPresetID == preset.id ? 1 : 0.72))
                                                        .padding(9)
                                                }
                                            Text(preset.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                                        }
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.selectedPresetID == preset.id ? .white.opacity(0.10) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.selectedPresetID == preset.id ? accent.opacity(0.85) : .white.opacity(0.07), lineWidth: model.selectedPresetID == preset.id ? 1.5 : 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Text(model.membershipActive ? "SKIN LIBRARY" : "KROMA PLUS · PRIVATE LIBRARY")
                                .font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.42))
                                .padding(.top, 4)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(model.filteredLibrarySkins) { skin in
                                    let isSelected = model.selectedImageURL?.lastPathComponent == skin.url.lastPathComponent
                                    Button { model.chooseLibrarySkin(skin) } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            Group {
                                                if let image = NSImage(contentsOf: skin.url) {
                                                    Image(nsImage: image).resizable().scaledToFill()
                                                } else {
                                                    RoundedRectangle(cornerRadius: 9)
                                                        .fill(.white.opacity(0.06))
                                                        .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.35)))
                                                }
                                            }
                                            .frame(height: 74)
                                            .frame(maxWidth: .infinity)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                            Text(skin.name)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.84))
                                        }
                                        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(isSelected ? .white.opacity(0.10) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? accent.opacity(0.85) : .white.opacity(0.07), lineWidth: isSelected ? 1.5 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .help(skin.id)
                                }
                            }
                            if model.filteredLibrarySkins.isEmpty {
                                Text(model.membershipActive ? "No skins match that search." : "Activate membership to load the 211 private skins.")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
            .padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func palettePicker(_ label: String, color: Binding<Color>) -> some View {
        VStack(spacing: 5) {
            ColorPicker(label, selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30, height: 28)
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
        }
        .accessibilityLabel("Palette color \(label)")
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(panel)
            if let url = model.selectedImageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 360, height: 227).clipShape(RoundedRectangle(cornerRadius: 22))
                LinearGradient(colors: [.black.opacity(0.18), .clear, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom).clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "creditcard.and.123").font(.system(size: 27)).foregroundStyle(accent)
                    Text("Skin preview").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    Text("Choose one of the looks →").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                }
            }
            VStack {
                HStack { Image(systemName: "wave.3.right"); Spacer(); Text("WALLET").font(.system(size: 8, weight: .bold)).tracking(1.4) }
                Spacer()
                HStack { Text("PREVIEW").font(.system(size: 8, weight: .bold)).tracking(1.5); Spacer(); Image(systemName: "sparkle") }
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.66)).padding(17)
        }
        .frame(width: 360, height: 227).clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 20, y: 10)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            KromaMark(size: 62)
            Text(model.isScanning ? "Listening for your Wallet card" : "Connect your iPhone to start")
                .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(model.isScanning ? "On your iPhone, open Wallet and tap the card you want to style." : model.status)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center).frame(maxWidth: 360)
            if !model.isScanning {
                Button { model.refresh() } label: { Label("Check connection", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 9) }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(ink).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

/// Kroma's own mark: a custom layered card with a spectrum edge, used in-app
/// and kept visually consistent with the app icon.
private struct KromaMark: View {
    var size: CGFloat = 42
    private let spectrum: [Color] = [
        Color(red: 0.99, green: 0.42, blue: 0.30),
        Color(red: 1.00, green: 0.69, blue: 0.31),
        Color(red: 0.39, green: 0.82, blue: 0.69),
        Color(red: 0.45, green: 0.59, blue: 0.98)
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.19, blue: 0.25), Color(red: 0.075, green: 0.09, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: size * 0.66, height: size * 0.48)
                .rotationEffect(.degrees(-12))
                .offset(x: -size * 0.055, y: -size * 0.10)
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Color(red: 0.94, green: 0.94, blue: 0.91))
                .frame(width: size * 0.66, height: size * 0.48)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 0) {
                        ForEach(Array(spectrum.enumerated()), id: \.offset) { _, color in color }
                    }
                    .frame(height: size * 0.075)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.04))
                    .padding(.horizontal, size * 0.08)
                    .padding(.bottom, size * 0.07)
                }
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: size * 0.025)
                        .fill(Color(red: 0.15, green: 0.18, blue: 0.24))
                        .frame(width: size * 0.14, height: size * 0.07)
                        .padding(.leading, size * 0.09)
                        .padding(.top, size * 0.12)
                }
                .rotationEffect(.degrees(7))
                .offset(x: size * 0.04, y: size * 0.05)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: size * 0.16, y: size * 0.07)
        .accessibilityLabel("Kroma")
    }
}
