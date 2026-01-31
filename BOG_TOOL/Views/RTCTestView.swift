import SwiftUI

/// RTC 测试：向 RTC UUID 写入十六进制，触发设备返回 RTC 并读取
struct RTCTestView: View {
    @ObservedObject var ble: BLEManager
    @State private var hexInput: String = "01"  // 默认触发命令示例
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RTC 手动触发")
                .font(.headline)
            
            if ble.isConnected {
                HStack(spacing: 8) {
                    Text("写入十六进制:")
                    TextField("例如 01 或 0x01", text: $hexInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    
                    Button("写入并读取 RTC") {
                        ble.writeRTCTrigger(hexString: hexInput)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                HStack(spacing: 12) {
                    Text("RTC 返回值:")
                    Text(ble.lastRTCValue)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(6)
                }
                
                Text("向 RTC UUID 写入指定十六进制后，设备会返回 RTC 时间，用于确认 RTC 模块正常。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("请先连接设备")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
    }
}
