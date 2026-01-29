import SwiftUI

/// 产测模式：连接后执行 开→关→开，并在开前/开后/关后各读一次压力
struct ProductionTestView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @State private var isRunning = false
    @State private var testLog: [String] = []
    @State private var stepIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguage.string("production_test.title"))
                .font(.headline)

            if ble.isConnected {
                HStack(alignment: .center, spacing: 8) {
                    Spacer(minLength: 8)
                    Button(action: runProductionTest) {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(isRunning ? appLanguage.string("production_test.running") : appLanguage.string("production_test.start"))
                        }
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }

                if !testLog.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appLanguage.string("production_test.log_title"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(testLog.enumerated()), id: \.offset) { i, line in
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .id(i)
                                    }
                                }
                            }
                            .frame(height: 88)
                            .onChange(of: testLog.count) { _ in
                                if let last = testLog.indices.last {
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            } else {
                Text(appLanguage.string("production_test.connect_first"))
                    .foregroundStyle(.secondary)
            }
            
            OTASectionView(ble: ble)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func runProductionTest() {
        guard ble.isConnected, !isRunning else { return }
        isRunning = true
        testLog.removeAll()
        stepIndex = 0
        
        func log(_ msg: String) {
            testLog.append("\(stepIndex): \(msg)")
            stepIndex += 1
        }
        
        Task { @MainActor in
            // 1. 开之前 — 读压力
            log("开阀前 - 读取压力")
            ble.readPressure()
            try? await Task.sleep(nanoseconds: 400_000_000)
            log("压力: \(ble.lastPressureValue)")
            
            // 2. 开阀
            log("电磁阀 开")
            ble.setValve(open: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            // 3. 开之后 — 读压力
            log("开阀后 - 读取压力")
            ble.readPressure()
            try? await Task.sleep(nanoseconds: 400_000_000)
            log("压力: \(ble.lastPressureValue)")
            
            // 4. 关阀
            log("电磁阀 关")
            ble.setValve(open: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            // 5. 关之后 — 读压力
            log("关阀后 - 读取压力")
            ble.readPressure()
            try? await Task.sleep(nanoseconds: 400_000_000)
            log("压力: \(ble.lastPressureValue)")
            
            // 6. 再次开阀（完成 开-关-开 一次）
            log("电磁阀 开")
            ble.setValve(open: true)
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            // 7. RTC 测试：写入触发后读取并解码
            log("RTC 测试 - 写入触发 01")
            ble.writeRTCTrigger(hexString: "01")
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("RTC 解码: \(ble.lastRTCValue)")
            
            log("产测流程结束")
            isRunning = false
        }
    }
}
