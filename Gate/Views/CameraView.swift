import SwiftUI
import AVKit

private let gateAccent = Color(red: 0.82, green: 0.96, blue: 0.40)
private let gatePanel = Color(red: 0.075, green: 0.085, blue: 0.078)

struct CameraView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ControlSheet?
    @State private var library = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                formatBar.padding(.top, 22).padding(.bottom, 18)
                monitor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                monitorTools.padding(.top, 16).padding(.bottom, 20)
                controlStrip
                transport.padding(.top, 25).padding(.bottom, geometry.size.height < 700 ? 4 : 16)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .background(Color(red: 0.025, green: 0.035, blue: 0.028))
        }
        .task { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() }
            else if phase == .background { camera.suspend() }
        }
        .onChange(of: camera.settings) { _, settings in camera.updateSettings(settings) }
        .sheet(item: $sheet) { kind in
            CameraControls(camera: camera, kind: kind)
                .presentationDetents(kind == .format ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $library) { ClipLibrary(camera: camera) }
        .alert("Capture notice", isPresented: Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })) {
            Button("OK") { camera.errorMessage = nil }
            if !camera.ready {
                Button("Retry") { camera.errorMessage = nil; camera.start() }
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } message: { Text(camera.errorMessage ?? "") }
        .statusBarHidden()
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: "viewfinder").font(.system(size: 23, weight: .light)).foregroundStyle(gateAccent)
                Text("gate").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-1.4)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(camera.recording ? Color.red : gateAccent).frame(width: 5, height: 5)
                Text(camera.recording ? "RECORDING" : camera.status)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
            }
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var formatBar: some View {
        HStack(spacing: 0) {
            Button { sheet = .format } label: {
                HStack(spacing: 7) {
                    Text(camera.settings.framing.shortName).foregroundStyle(gateAccent)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer()
            Text(camera.settings.longEdge == 4032 ? "12MP" : camera.settings.longEdge == 3840 ? "4K" : "HD")
            Text("/").foregroundStyle(.white.opacity(0.25)).padding(.horizontal, 8)
            Text("\(camera.settings.fps) FPS")
            Text("/").foregroundStyle(.white.opacity(0.25)).padding(.horizontal, 8)
            Text(camera.settings.profile == .gateLog ? "GATE LOG" : "REC.709")
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(0.8)
        .foregroundStyle(.white.opacity(0.65))
    }

    private var monitor: some View {
        GeometryReader { geometry in
            let ratio = camera.settings.framing.portraitRatio
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let height = width / ratio
            ZStack {
                Color.black
                // The UI hosts the layer; only the camera queue connects it, after
                // idle RAW requests have drained. Layout does not change capture state.
                if !camera.demo {
                    SystemCameraPreview(previewLayer: camera.systemPreviewLayer)
                        .opacity(camera.usesSystemPreview ? 1 : 0)
                }
                if !camera.usesSystemPreview, let preview = camera.preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit()
                } else if !camera.usesSystemPreview {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.aperture").font(.system(size: 32, weight: .ultraLight))
                        Text(camera.ready ? "DEVELOPING RAW" : camera.status)
                            .font(.system(size: 10, design: .monospaced)).tracking(1)
                    }.foregroundStyle(.white.opacity(0.45))
                }
                if camera.settings.grid { ThirdsGrid().stroke(.white.opacity(0.17), lineWidth: 0.5) }
                VStack {
                    HStack {
                        Text(camera.demo ? "DEMO" : "RAW")
                            .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        if camera.recording {
                            HStack(spacing: 5) {
                                Circle().fill(.red).frame(width: 5, height: 5)
                                Text(timecode).monospacedDigit()
                            }.font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Spacer()
                    HStack {
                        Text(camera.usesSystemPreview ? "SYSTEM PREVIEW" : camera.settings.gammaAssist ? "709 ASSIST" : camera.settings.profile.rawValue.uppercased())
                        Spacer()
                        Text("1× / 24mm")
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black, radius: 4)
                }.padding(13)
                ViewfinderCorners().stroke(.white.opacity(0.55), lineWidth: 1).padding(5)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var monitorTools: some View {
        HStack(spacing: 16) {
            assistButton("grid", label: "Thirds grid", active: camera.settings.grid) { camera.settings.grid.toggle() }
            assistButton("circle.lefthalf.filled", label: "Rec.709 gamma assist", active: camera.settings.gammaAssist) { camera.settings.gammaAssist.toggle() }
                .disabled(camera.usesSystemPreview).opacity(camera.usesSystemPreview ? 0.3 : 1)
            assistButton("line.3.horizontal", label: "Zebras", active: camera.settings.assist == .zebras) {
                camera.settings.assist = camera.settings.assist == .zebras ? .off : .zebras
            }
            .disabled(camera.usesSystemPreview).opacity(camera.usesSystemPreview ? 0.3 : 1)
            assistButton("paintpalette", label: "False color", active: camera.settings.assist == .falseColor) {
                camera.settings.assist = camera.settings.assist == .falseColor ? .off : .falseColor
            }
            .disabled(camera.usesSystemPreview).opacity(camera.usesSystemPreview ? 0.3 : 1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f", camera.measuredFPS) + " FPS")
                    .foregroundStyle(camera.recording && camera.measuredFPS < Double(camera.settings.fps) * 0.85 ? .orange : .white.opacity(0.55))
                Text(camera.recording ? "\(camera.skipped) SKIPPED" : "IDLE MONITOR")
                    .font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.28))
            }.font(.system(size: 9, weight: .medium, design: .monospaced))
        }
    }

    private func assistButton(_ icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .regular))
                .foregroundStyle(active ? gateAccent : .white.opacity(0.35))
                .frame(width: 25, height: 30)
        }.accessibilityLabel(label).accessibilityValue(active ? "On" : "Off")
    }

    private var controlStrip: some View {
        HStack(spacing: 1) {
            control("ISO", value: "\(Int(camera.actualISO))", detail: camera.settings.autoExposure ? "AUTO" : "MANUAL", kind: .exposure)
            control("SHUTTER", value: "1/\(Int(camera.actualShutter.rounded()))", detail: camera.settings.autoExposure ? "AUTO" : "MANUAL", kind: .exposure)
            control("WB", value: "\(Int(camera.settings.whiteBalance))", detail: "KELVIN", kind: .whiteBalance)
            control("FOCUS", value: camera.settings.autoFocus ? (camera.recording ? "LOCK" : "AF") : String(format: "%.2f", camera.settings.focus), detail: camera.recording ? "LOCKED" : "SET", kind: .focus)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06)))
    }

    private func control(_ title: String, value: String, detail: String, kind: ControlSheet) -> some View {
        Button { sheet = kind } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.35))
                Text(value).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).minimumScaleFactor(0.7)
                Text(detail).font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(gateAccent.opacity(0.65))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 13).padding(.vertical, 14).background(gatePanel)
        }.buttonStyle(.plain)
    }

    private var transport: some View {
        HStack {
            Button { camera.refreshClips(); library = true } label: {
                VStack(spacing: 7) {
                    Image(systemName: "square.stack").font(.system(size: 20, weight: .light))
                    Text("CLIPS \(camera.clips.count)").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                }.frame(width: 70).foregroundStyle(.white.opacity(0.5))
            }.accessibilityLabel("Open clips")
            Spacer()
            Button { camera.toggleRecording() } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.35), lineWidth: 1.5).frame(width: 72, height: 72)
                    if camera.finalizing || camera.preparingTake {
                        ProgressView().tint(gateAccent)
                    } else if camera.recording {
                        RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0.3, blue: 0.27)).frame(width: 25, height: 25)
                    } else {
                        Circle().fill(Color(red: 1, green: 0.3, blue: 0.27)).frame(width: 58, height: 58)
                    }
                }
            }
            .disabled(!camera.ready || camera.finalizing || camera.preparingTake)
            .opacity(camera.ready ? 1 : 0.4)
            .accessibilityLabel(camera.recording ? "Stop recording" : "Start recording")
            Spacer()
            Button { sheet = .format } label: {
                VStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .light))
                    Text(camera.settings.codec.shortName).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                }.frame(width: 70).foregroundStyle(.white.opacity(0.5))
            }.accessibilityLabel("Recording settings")
        }
    }

    private var timecode: String {
        let seconds = Int(camera.elapsed)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for fraction in [1.0 / 3, 2.0 / 3] {
                path.move(to: CGPoint(x: rect.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
                path.move(to: CGPoint(x: 0, y: rect.height * fraction))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
            }
        }
    }
}

private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for x in [rect.minX, rect.maxX] {
                for y in [rect.minY, rect.maxY] {
                    let dx: CGFloat = x == rect.minX ? 12 : -12
                    let dy: CGFloat = y == rect.minY ? 12 : -12
                    path.move(to: CGPoint(x: x + dx, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + dy))
                }
            }
        }
    }
}

enum ControlSheet: String, Identifiable {
    case format = "Recording settings"
    case exposure = "Exposure"
    case whiteBalance = "White balance"
    case focus = "Focus"
    var id: String { rawValue }
}

private struct CameraControls: View {
    @ObservedObject var camera: CameraController
    let kind: ControlSheet
    @Environment(\.dismiss) private var dismiss
    private var locked: Bool { camera.recording || camera.finalizing }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .format: formatControls
                case .exposure: exposureControls
                case .whiteBalance: whiteBalanceControls
                case .focus: focusControls
                }
            }
            .tint(gateAccent)
            .navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(gateAccent) } }
        }.preferredColorScheme(.dark)
    }

    private var formatControls: some View {
        Group {
            Section {
                Picker("Frame", selection: $camera.settings.framing) { ForEach(Framing.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Resolution", selection: $camera.settings.longEdge) {
                    Text("HD · 1920 long edge").tag(1920)
                    Text("4K · 3840 long edge").tag(3840)
                    Text("12 MP · 4032 long edge").tag(4032)
                }
                Picker("Target frame rate", selection: $camera.settings.fps) {
                    ForEach([12, 24, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Codec", selection: $camera.settings.codec) { ForEach(RecordingCodec.allCases) { Text($0.rawValue).tag($0) } }
                if camera.settings.codec == .hevc {
                    Picker("Bitrate", selection: $camera.settings.bitrateMbps) {
                        ForEach([30, 60, 100, 150], id: \.self) { Text("\($0) Mbps").tag($0) }
                    }
                }
                Picker("Color", selection: $camera.settings.profile) { ForEach(ColorProfile.allCases) { Text($0.rawValue).tag($0) } }
            } header: { Text("Capture") } footer: {
                Text("Frame rate is a target. The 4032 option preserves the full 12 MP open gate frame on iPhone 16 Pro (3024 × 4032 in portrait). Format is fixed for each take.")
            }.disabled(locked)
            Section("RAW development") {
                Toggle("Lens correction", isOn: $camera.settings.lensCorrection)
                VStack(alignment: .leading) {
                    Text("Noise reduction · \(Int(camera.settings.noiseReduction * 100))%")
                    Slider(value: $camera.settings.noiseReduction, in: 0...1)
                }
            }
            Section("Monitor") {
                Toggle("Rec.709 gamma assist", isOn: $camera.settings.gammaAssist)
                    .disabled(camera.usesSystemPreview)
                Toggle("Thirds grid", isOn: $camera.settings.grid)
                Picker("Exposure assist", selection: $camera.settings.assist) { ForEach(ExposureAssist.allCases) { Text($0.rawValue).tag($0) } }
                    .disabled(camera.usesSystemPreview)
                Text("During recording the monitor switches to Apple's system video preview to save resources. RAW gamma and exposure assists are available before the take; the recording continues to use RAW frames. False color: violet / blue = shadows, green ≈ 42 IRE, pink = 55–65 IRE, yellow = highlights, red > 95 IRE.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let lut = Bundle.main.url(forResource: "GateLog_to_Rec709", withExtension: "cube") {
                    ShareLink(item: lut) { Label("Export Gate Log conversion LUT", systemImage: "square.and.arrow.up") }
                }
                Text("Bayer RAW → linear Rec.709 → Gate Log or Rec.709 → movie. Gate Log uses log₂(1 + 15x) / 4. It is a custom profile; use the included inverse LUT when grading.")
                Text("Prototype: wide camera, portrait orientation, silent video. Encoder input is 8-bit for both codecs. 10-bit capture, audio, external drives, gyro data, and imported LUTs are future work.")
            } header: { Text("About this build") }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exposureControls: some View {
        Group {
            Section {
                Toggle("Auto exposure", isOn: $camera.settings.autoExposure)
                if camera.settings.autoExposure {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(format: "Exposure compensation · %+.1f EV", camera.settings.ev))
                        Slider(value: $camera.settings.ev, in: -2...2, step: 0.1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ISO \(Int(camera.settings.iso))")
                        Slider(value: $camera.settings.iso, in: camera.isoRange, step: 1)
                    }
                    Picker("Shutter", selection: $camera.settings.shutterDenominator) {
                        ForEach([30.0, 48, 50, 60, 100, 120, 250, 500, 1000], id: \.self) { Text("1/\(Int($0)) s").tag($0) }
                    }
                }
            } footer: { Text("For a natural motion blur at \(camera.settings.fps) fps, start around 1/\(camera.settings.fps * 2) s. Actual ISO and shutter appear on the camera screen. Long exposures are clamped to the target frame interval.") }
        }
    }

    private var whiteBalanceControls: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(Int(camera.settings.whiteBalance)) K").font(.system(.title2, design: .monospaced))
                Slider(value: $camera.settings.whiteBalance, in: 2500...10000, step: 100)
                HStack {
                    ForEach([3200, 4300, 5600, 6500], id: \.self) { value in
                        Button("\(value)") { camera.settings.whiteBalance = Float(value) }
                            .buttonStyle(.bordered)
                    }
                }
            }.padding(.vertical, 10)
        } footer: { Text("White balance is applied during RAW development. Keep it fixed across a take for consistent color.") }
    }

    private var focusControls: some View {
        Section {
            Toggle("Autofocus before recording", isOn: $camera.settings.autoFocus)
            if !camera.settings.autoFocus {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Lens position · " + String(format: "%.2f", camera.settings.focus))
                    Slider(value: $camera.settings.focus, in: 0...1)
                    HStack { Text("Near"); Spacer(); Text("Far") }.font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: { Text("Focus locks when a take starts. Set your subject before recording.") }.disabled(locked)
    }
}

private struct ClipLibrary: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if camera.clips.isEmpty {
                    ContentUnavailableView("Your first take awaits", systemImage: "film.stack", description: Text("Record a clip, then review and share it here."))
                } else {
                    List(camera.clips) { clip in
                        NavigationLink {
                            ClipPlayer(clip: clip)
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: "play.rectangle").font(.title).foregroundStyle(gateAccent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.date.formatted(date: .abbreviated, time: .standard)).font(.subheadline)
                                    Text(clip.size + " · MOV").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 7)
                        }
                    }
                }
            }
            .navigationTitle("Clips")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(gateAccent) } }
        }.preferredColorScheme(.dark)
    }
}

private struct ClipPlayer: View {
    let clip: Clip
    @State private var player: AVPlayer?
    var body: some View {
        VStack(spacing: 24) {
            VideoPlayer(player: player).aspectRatio(3 / 4, contentMode: .fit)
            ShareLink(item: clip.url) { Label("Share movie", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).tint(gateAccent).foregroundStyle(.black)
            ShareLink(item: clip.url.deletingPathExtension().appendingPathExtension("json")) {
                Label("Share capture metadata", systemImage: "doc.text")
            }.foregroundStyle(gateAccent)
            Text("Original clips are also available in Files → On My iPhone → Gate → Clips.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding().navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
            .onAppear { player = AVPlayer(url: clip.url) }
            .onDisappear { player?.pause(); player = nil }
    }
}

#Preview { CameraView(camera: CameraController()) }
