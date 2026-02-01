import SwiftUI

/// UI设计系统：统一的间距、填充、字体、颜色等设计常量
/// 用于确保整个应用的视觉一致性和可维护性
enum UIDesignSystem {
    
    // MARK: - Spacing（间距：用于组件之间的间距）
    
    enum Spacing {
        /// 极小间距（4pt）：标签和值之间、紧密排列的元素
        static let xs: CGFloat = 4
        
        /// 小间距（6pt）：紧凑区域内的元素间距
        static let sm: CGFloat = 6
        
        /// 中等间距（8pt）：标准区域内的元素间距
        static let md: CGFloat = 8
        
        /// 大间距（12pt）：区域之间的间距、主要元素之间的间距
        static let lg: CGFloat = 12
        
        /// 超大间距（16pt）：主要区域之间的间距
        static let xl: CGFloat = 16
        
        /// 极大间距（20pt）：模态对话框、页面级别的间距
        static let xxl: CGFloat = 20
    }
    
    // MARK: - Padding（内边距：用于组件内部的空间）
    
    enum Padding {
        /// 极小内边距（4pt）：紧凑的标签、徽章
        static let xs: CGFloat = 4
        
        /// 小内边距（6pt）：紧凑区域、小卡片
        static let sm: CGFloat = 6
        
        /// 标准内边距（8pt）：标准区域、卡片内容
        static let md: CGFloat = 8
        
        /// 大内边距（12pt）：主要区域、对话框内容
        static let lg: CGFloat = 12
        
        /// 超大内边距（16pt）：页面级别、大对话框
        static let xl: CGFloat = 16
    }
    
    // MARK: - Typography（字体系统）
    
    enum Typography {
        /// 页面标题：大标题，用于页面顶部
        static let pageTitle: Font = .system(.title2, weight: .semibold)
        
        /// 区域标题：中等标题，用于主要区域
        static let sectionTitle: Font = .system(.headline, weight: .medium)
        
        /// 子区域标题：小标题，用于子区域
        static let subsectionTitle: Font = .system(.subheadline, weight: .medium)
        
        /// 正文：标准正文文本
        static let body: Font = .system(.body)
        
        /// 说明文字：小号文本，用于辅助说明
        static let caption: Font = .system(.caption)
        
        /// 等宽字体：用于代码、数据、日志
        static let monospaced: Font = .system(.body, design: .monospaced)
        
        /// 等宽说明文字：用于代码、数据的小号文本
        static let monospacedCaption: Font = .system(.caption, design: .monospaced)
    }
    
    // MARK: - Colors（颜色系统）
    
    enum Background {
        /// 最轻微背景：几乎不可见的背景色
        static let subtle: Color = .primary.opacity(0.03)
        
        /// 轻微背景：轻微的背景色，用于区分区域
        static let light: Color = .primary.opacity(0.04)
        
        /// 中等背景：中等强度的背景色
        static let medium: Color = .primary.opacity(0.08)
        
        /// 卡片背景：使用系统控件背景色
        static let card: Color = Color(nsColor: .controlBackgroundColor)
        
        /// 窗口背景：使用系统窗口背景色
        static let window: Color = Color(nsColor: .windowBackgroundColor)
        
        /// 文本背景：使用系统文本背景色
        static let text: Color = Color(nsColor: .textBackgroundColor)
    }
    
    enum Foreground {
        /// 主要文本颜色
        static let primary: Color = .primary
        
        /// 次要文本颜色
        static let secondary: Color = .secondary
        
        /// 强调色（使用系统强调色）
        static let accent: Color = .accentColor
    }
    
    // MARK: - Corner Radius（圆角）
    
    enum CornerRadius {
        /// 极小圆角（3pt）：进度条、小元素
        static let xs: CGFloat = 3
        
        /// 小圆角（6pt）：小按钮、小卡片
        static let sm: CGFloat = 6
        
        /// 中等圆角（8pt）：标准卡片、区域
        static let md: CGFloat = 8
        
        /// 大圆角（12pt）：大卡片、对话框
        static let lg: CGFloat = 12
        
        /// 超大圆角（16pt）：模态对话框、大卡片
        static let xl: CGFloat = 16
    }
    
    // MARK: - Component Sizes（组件尺寸）
    
    enum Component {
        /// 标准操作按钮宽度
        static let actionButtonWidth: CGFloat = 96
        
        /// 小按钮宽度
        static let smallButtonWidth: CGFloat = 80
        
        /// 大按钮宽度
        static let largeButtonWidth: CGFloat = 120
        
        /// 标准进度条高度（非模态）
        static let progressBarHeight: CGFloat = 8
        
        /// 模态进度条高度
        static let modalProgressBarHeight: CGFloat = 12
        
        /// 设备列表表格高度
        static let deviceTableHeight: CGFloat = 140
        
        /// 测试日志区域高度
        static let testLogHeight: CGFloat = 88
    }
    
    // MARK: - Window Sizes（窗口尺寸）
    
    enum Window {
        /// 最小窗口宽度
        static let minWidth: CGFloat = 760
        
        /// 最小窗口高度
        static let minHeight: CGFloat = 520
        
        /// 默认窗口宽度
        static let defaultWidth: CGFloat = 1200
        
        /// 默认窗口高度
        static let defaultHeight: CGFloat = 900
        
        /// 左侧面板最小宽度
        static let leftPanelMinWidth: CGFloat = 360
        
        /// 右侧日志面板最小宽度
        static let rightPanelMinWidth: CGFloat = 380
    }
    
    // MARK: - Animation（动画）
    
    enum Animation {
        /// 快速动画时长（用于即时反馈）
        static let fast: SwiftUI.Animation = .easeInOut(duration: 0.15)
        
        /// 标准动画时长（用于一般过渡）
        static let standard: SwiftUI.Animation = .easeInOut(duration: 0.2)
        
        /// 慢速动画时长（用于复杂过渡）
        static let slow: SwiftUI.Animation = .easeInOut(duration: 0.3)
        
        /// 弹性动画（用于状态变化）
        static let spring: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.7)
    }
    
    // MARK: - Opacity（透明度）
    
    enum Opacity {
        /// 禁用状态透明度
        static let disabled: Double = 0.5
        
        /// 覆盖层透明度（中等）
        static let overlay: Double = 0.6
        
        /// 覆盖层透明度（高）
        static let overlayHigh: Double = 0.8
        
        /// 背景透明度（轻微）
        static let backgroundSubtle: Double = 0.03
        
        /// 背景透明度（轻微）
        static let backgroundLight: Double = 0.04
        
        /// 背景透明度（中等）
        static let backgroundMedium: Double = 0.08
        
        /// 背景透明度（明显）
        static let backgroundStrong: Double = 0.15
    }
}
