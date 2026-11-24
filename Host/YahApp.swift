import SwiftUI

@main
struct YahApp: App {
    @State private var sample = ""
    var body: some Scene {
        WindowGroup {
            Form {
                Text("在系统设置 → 通用 → 键盘 → 键盘 → 添加新键盘中启用 Yah。")
                TextField("切换到 Yah 后输入 nihao", text: $sample)
            }
        }
    }
}
