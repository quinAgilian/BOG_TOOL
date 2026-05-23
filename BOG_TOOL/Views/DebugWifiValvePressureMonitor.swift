import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

private enum WifiValvePressureKeys {
    static let interval = "debug_wifi_valve_pressure_interval_sec"
    static let duration = "debug_wifi_valve_pressure_duration_sec"
}

private struct WifiValvePressureSample: Identifiable {
    let id = UUID()
    let time: Double
    let pressureMbar: Double
    let temperatureC: Double?
}

/// Debug：连续轮询 WiFi 辅材 `/pressure` 并实时绘图（mbar vs 时间）
struct DebugWifiValvePressureMonitor: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var auxValveSettings: AuxValveSettings

    @State private var durationSeconds: Int = {
        UserDefaults.standard.object(forKey: WifiValvePressureKeys.duration) as? Int ?? 300
    }()
    @State private var durationInput: String = {
        let v = UserDefaults.standard.object(forKey: WifiValvePressureKeys.duration) as? Int ?? 300
        return "\(v)"
    }()
    @State private var intervalSec: Double = {
        UserDefaults.standard.object(forKey: WifiValvePressureKeys.interval) as? Double ?? 0.5
    }()
    @State private var intervalInput: String = {
        let v = UserDefaults.standard.object(forKey: WifiValvePressureKeys.interval) as? Double ?? 0.5
        return String(format: "%.2f", v)
    }()

    @State private var isRunning = false
    @State private var elapsedSec: Double = 0
    @State private var samples: [WifiValvePressureSample] = []
    @State private var currentPressureMbar: Double?
    @State private var currentTemperatureC: Double?
    @State private var lastErrorMessage: String = ""
    @State private var errorCount = 0
    @State private var monitorTask: Task<Void, Never>?
    @State private var visibleWindowSeconds: Int? = nil
    @State private var autoYScale = true
    @State private var hoverSample: WifiValvePressureSample?
    @State private var hoverPosition: CGPoint?

    private let client = AuxValveWiFiClient()

    private var canStart: Bool {
        auxValveSettings.enabled && !auxValveSettings.normalizedTargetDeviceId.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            if !canStart {
                Text(appLanguage.string("debug.wifi_valve_pressure.configure_hint"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Button(appLanguage.string("debug.wifi_valve_pressure.open_settings")) {
                    auxValveSettings.showAuxValveSettingsSheet = true
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                Spacer(minLength: UIDesignSystem.Spacing.sm)
                if isRunning {
                    Button { stopMonitoring(reason: appLanguage.string("debug.wifi_valve_pressure.stop_reason_user")) } label: {
                        Text(appLanguage.string("debug.gas_leak_stop"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { startMonitoring() } label: {
                        Text(appLanguage.string("debug.gas_leak_start"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                }
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                durationControl
                intervalControl
            }
            .disabled(isRunning)

            if !samples.isEmpty || isRunning {
                chartControls
                pressureChart
                    .frame(height: 220)
                statusBar
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .onDisappear {
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    private var durationControl: some View {
        HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("debug.gas_leak_duration"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            TextField("", text: $durationInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 44, maxWidth: 56)
                .multilineTextAlignment(.trailing)
                .onSubmit(persistDurationFromInput)
            Text(appLanguage.string("debug.gas_leak_duration_unit"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Stepper("", value: $durationSeconds, in: 0...3600, step: 10)
                .labelsHidden()
                .onChange(of: durationSeconds) {
                    durationInput = "\($0)"
                    UserDefaults.standard.set($0, forKey: WifiValvePressureKeys.duration)
                }
        }
    }

    private var intervalControl: some View {
        HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("debug.gas_leak_interval"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            TextField("", text: $intervalInput)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 40, maxWidth: 52)
                .multilineTextAlignment(.trailing)
                .onSubmit(persistIntervalFromInput)
            Stepper("", value: $intervalSec, in: 0.1...5.0, step: 0.1)
                .labelsHidden()
                .onChange(of: intervalSec) {
                    intervalInput = String(format: "%.2f", $0)
                    UserDefaults.standard.set($0, forKey: WifiValvePressureKeys.interval)
                }
        }
    }

    private var chartControls: some View {
        HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.gas_leak_chart_show"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Picker("", selection: $visibleWindowSeconds) {
                Text(appLanguage.string("debug.gas_leak_chart_show_full")).tag(nil as Int?)
                Text(appLanguage.string("debug.gas_leak_chart_show_last_10s")).tag(10 as Int?)
                Text(appLanguage.string("debug.gas_leak_chart_show_last_30s")).tag(30 as Int?)
                Text(appLanguage.string("debug.gas_leak_chart_show_last_60s")).tag(60 as Int?)
                Text(appLanguage.string("debug.gas_leak_chart_show_last_120s")).tag(120 as Int?)
                Text(appLanguage.string("debug.gas_leak_chart_show_last_300s")).tag(300 as Int?)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: UIDesignSystem.FormRow.pickerMinWidth, maxWidth: 140)
            Spacer()
            Toggle("", isOn: $autoYScale)
                .toggleStyle(.switch)
                .labelsHidden()
            Text(appLanguage.string("debug.gas_leak_chart_auto_y"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Button(appLanguage.string("debug.wifi_valve_pressure.export_csv")) {
                exportCSV()
            }
            .buttonStyle(.bordered)
            .font(UIDesignSystem.Typography.caption)
            .disabled(samples.isEmpty)
        }
    }

    private var pressureChart: some View {
        let timeKey = appLanguage.string("debug.gas_leak_chart_time_label")
        let pressureKey = appLanguage.string("debug.wifi_valve_pressure.series_label")
        let domain = chartXDomain
        let yDomain = chartYDomain
        let step = Self.chartTimeStride(durationSeconds: Int(max(domain.max - domain.min, 1)))

        return Chart {
            ForEach(visibleSamples) { sample in
                LineMark(
                    x: .value(timeKey, sample.time),
                    y: .value(pressureKey, sample.pressureMbar)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(by: .value("", pressureKey))
                PointMark(
                    x: .value(timeKey, sample.time),
                    y: .value(pressureKey, sample.pressureMbar)
                )
                .foregroundStyle(by: .value("", pressureKey))
                .symbolSize(samples.count > 80 ? 0 : 18)
            }
        }
        .chartForegroundStyleScale([pressureKey: Color.teal])
        .chartLegend(position: .top, alignment: .leading, spacing: 8)
        .chartXScale(domain: domain.min ... domain.max)
        .chartYScale(domain: yDomain.min ... yDomain.max)
        .chartXAxis {
            AxisMarks(values: .stride(by: step)) { value in
                AxisGridLine()
                if let v = value.as(Double.self) {
                    AxisValueLabel("\(Int(v))")
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                if let v = value.as(Double.self) {
                    AxisValueLabel(String(format: "%.0f", v))
                }
            }
        }
        .chartYAxisLabel { Text(appLanguage.string("debug.gas_leak_chart_pressure_label")) }
        .chartXAxisLabel { Text(timeKey) }
        .chartOverlay { proxy in
            chartHoverOverlay(proxy: proxy, timeKey: timeKey, pressureKey: pressureKey)
        }
    }

    private var statusBar: some View {
        HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
            Text("\(appLanguage.string("debug.gas_leak_elapsed")) \(isRunning || !samples.isEmpty ? String(format: "%.1f s", elapsedSec) : "--")")
            Text("·")
            Text("\(appLanguage.string("debug.wifi_valve_pressure.current")) \(currentPressureMbar.map { String(format: "%.1f mbar", $0) } ?? "--")")
            Text("·")
            Text("\(appLanguage.string("debug.wifi_valve_pressure.temperature")) \(currentTemperatureC.map { String(format: "%.1f °C", $0) } ?? "--")")
            Text("·")
            Text("\(appLanguage.string("debug.wifi_valve_pressure.samples")) \(samples.count)")
            if errorCount > 0 {
                Text("·")
                Text("\(appLanguage.string("debug.wifi_valve_pressure.errors")) \(errorCount)")
                    .foregroundStyle(.orange)
            }
            if !lastErrorMessage.isEmpty, !isRunning {
                Text("·")
                Text(lastErrorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Text(appLanguage.string("debug.wifi_valve_pressure.device_id_label") + " \(auxValveSettings.normalizedTargetDeviceId)")
                .font(UIDesignSystem.Typography.monospacedCaption)
        }
        .font(UIDesignSystem.Typography.caption)
        .foregroundStyle(UIDesignSystem.Foreground.secondary)
        .padding(.horizontal, UIDesignSystem.Padding.sm)
        .padding(.vertical, UIDesignSystem.Padding.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }

    @ViewBuilder
    private func chartHoverOverlay(proxy: ChartProxy, timeKey: String, pressureKey: String) -> some View {
        GeometryReader { geo in
            let plotFrame = geo[proxy.plotAreaFrame]
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard plotFrame.contains(location),
                              let t: Double = proxy.value(atX: location.x, as: Double.self),
                              let sample = nearestSample(to: t) else {
                            hoverSample = nil
                            hoverPosition = nil
                            return
                        }
                        hoverSample = sample
                        if let xInPlot = proxy.position(forX: sample.time) {
                            hoverPosition = CGPoint(x: xInPlot + plotFrame.origin.x, y: plotFrame.minY + 24)
                        }
                    case .ended:
                        hoverSample = nil
                        hoverPosition = nil
                    }
                }

            if let sample = hoverSample, let pt = hoverPosition {
                Path { path in
                    path.move(to: CGPoint(x: pt.x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: pt.x, y: plotFrame.maxY))
                }
                .stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(timeKey): \(String(format: "%.2f s", sample.time))")
                    Text("\(pressureKey): \(String(format: "%.1f mbar", sample.pressureMbar))")
                    if let temp = sample.temperatureC {
                        Text("\(appLanguage.string("debug.wifi_valve_pressure.temperature")) \(String(format: "%.1f °C", temp))")
                    }
                }
                .font(UIDesignSystem.Typography.monospacedCaption)
                .padding(8)
                .background(.thinMaterial)
                .cornerRadius(8)
                .position(x: min(max(plotFrame.minX + 110, pt.x + 10), plotFrame.maxX - 110), y: pt.y)
            }
        }
    }

    private var visibleSamples: [WifiValvePressureSample] {
        guard let window = visibleWindowSeconds, let last = samples.last?.time else { return samples }
        let minT = max(0, last - Double(window))
        return samples.filter { $0.time >= minT }
    }

    private var chartXDomain: (min: Double, max: Double) {
        let visible = visibleSamples
        guard let first = visible.first?.time, let last = visible.last?.time else {
            return (0, max(elapsedSec, 1))
        }
        if first == last {
            return (max(0, first - 1), last + 1)
        }
        return (first, last)
    }

    private var chartYDomain: (min: Double, max: Double) {
        let values = visibleSamples.map(\.pressureMbar)
        guard !values.isEmpty else { return (0, 100) }
        guard autoYScale else { return (0, max(values.max() ?? 100, 100)) }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 100
        let span = max(maxV - minV, 20)
        let pad = span * 0.08
        return (minV - pad, maxV + pad)
    }

    private func nearestSample(to time: Double) -> WifiValvePressureSample? {
        guard !visibleSamples.isEmpty else { return nil }
        return visibleSamples.min(by: { abs($0.time - time) < abs($1.time - time) })
    }

    private func persistDurationFromInput() {
        let v = Int(durationInput.trimmingCharacters(in: .whitespaces)) ?? durationSeconds
        let clamped = min(3600, max(0, v))
        durationSeconds = clamped
        durationInput = "\(clamped)"
        UserDefaults.standard.set(clamped, forKey: WifiValvePressureKeys.duration)
    }

    private func persistIntervalFromInput() {
        let raw = intervalInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let v = Double(raw) ?? intervalSec
        let clamped = min(5.0, max(0.1, v))
        intervalSec = clamped
        intervalInput = String(format: "%.2f", clamped)
        UserDefaults.standard.set(clamped, forKey: WifiValvePressureKeys.interval)
    }

    private func resetSession() {
        samples.removeAll()
        elapsedSec = 0
        currentPressureMbar = nil
        currentTemperatureC = nil
        lastErrorMessage = ""
        errorCount = 0
        hoverSample = nil
        hoverPosition = nil
    }

    private func startMonitoring() {
        persistDurationFromInput()
        persistIntervalFromInput()
        monitorTask?.cancel()
        resetSession()
        isRunning = true
        let interval = intervalSec
        auxValveSettings.auxHttpTraceEnabled = true
        auxValveSettings.auxLog(
            "[DBG][WiFiValve] start monitor device=\(auxValveSettings.normalizedTargetDeviceId) "
            + "duration=\(durationSeconds == 0 ? "∞" : "\(durationSeconds)s") interval=\(String(format: "%.2f", interval))s",
            level: .info
        )
        monitorTask = Task {
            let phaseStart = Date()
            let infinite = durationSeconds == 0
            defer {
                Task { @MainActor in
                    isRunning = false
                }
            }
            if infinite {
                var sampleIndex = 0
                while !Task.isCancelled {
                    let elapsed = Date().timeIntervalSince(phaseStart)
                    await sampleOnce(elapsed: elapsed)
                    if Task.isCancelled { break }
                    sampleIndex += 1
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            } else {
                let sampleTimes = GasLeakPhaseTiming.sampleTimes(durationSeconds: durationSeconds, intervalSeconds: interval)
                for (index, elapsed) in sampleTimes.enumerated() {
                    if Task.isCancelled { break }
                    await GasLeakPhaseTiming.waitUntil(phaseStart: phaseStart, targetT: elapsed)
                    await sampleOnce(elapsed: elapsed)
                    if index + 1 >= sampleTimes.count, !Task.isCancelled {
                        await MainActor.run {
                            stopMonitoring(reason: String(format: appLanguage.string("debug.continuous_pressure_stop_reason_duration"), durationSeconds))
                        }
                    }
                }
            }
        }
    }

    private func sampleOnce(elapsed: Double) async {
        do {
            let reading = try await client.fetchPressure(settings: auxValveSettings)
            await MainActor.run {
                elapsedSec = elapsed
                if reading.valid, let mbar = reading.pressureMbar {
                    currentPressureMbar = mbar
                    currentTemperatureC = reading.temperatureC
                    samples.append(WifiValvePressureSample(
                        time: elapsed,
                        pressureMbar: mbar,
                        temperatureC: reading.temperatureC
                    ))
                    lastErrorMessage = ""
                } else if !reading.sensorOk {
                    errorCount += 1
                    lastErrorMessage = appLanguage.string("debug.wifi_valve_pressure.sensor_not_ok")
                } else {
                    errorCount += 1
                    lastErrorMessage = appLanguage.string("debug.wifi_valve_pressure.invalid_sample")
                }
            }
        } catch {
            await MainActor.run {
                errorCount += 1
                elapsedSec = elapsed
                lastErrorMessage = AuxValveUserMessage.localize(AuxValveUserMessage.from(error), language: appLanguage)
            }
        }
    }

    private func stopMonitoring(reason: String) {
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
        auxValveSettings.auxLog("[DBG][WiFiValve] stop: \(reason) samples=\(samples.count) errors=\(errorCount)", level: .info)
    }

    private func exportCSV() {
        var lines = ["time_s,pressure_mbar,temperature_c"]
        for s in samples {
            let temp = s.temperatureC.map { String(format: "%.2f", $0) } ?? ""
            lines.append(String(format: "%.3f,%.3f,%@", s.time, s.pressureMbar, temp))
        }
        let csv = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.title = appLanguage.string("debug.wifi_valve_pressure.export_csv")
        panel.nameFieldStringValue = "wifi_valve_pressure_\(auxValveSettings.normalizedTargetDeviceId)_\(Int(Date().timeIntervalSince1970)).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func chartTimeStride(durationSeconds: Int) -> Double {
        let d = Double(max(1, durationSeconds))
        if d <= 15 { return 1 }
        if d <= 60 { return 5 }
        if d <= 180 { return 10 }
        if d <= 600 { return 30 }
        return 60
    }
}
