import Foundation
import SwiftUI

/// Product and local-data information inside the standard panel canvas.
public struct AboutPage: View {
    public let onBack: () -> Void

    public init(onBack: @escaping () -> Void) {
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            SubpageBar(title: "关于", onBack: onBack)
            ScrollView(.vertical) {
                VStack(spacing: Theme.Space.m) {
                    identityPanel
                    featuresPanel
                    privacyPanel
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var identityPanel: some View {
        Panel(padding: Theme.Space.m, spacing: Theme.Space.s) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 32)
                    .accessibilityHidden(true)
                Text("FiberHome CPE Manager")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text(versionLabel)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.inkMuted)
                    .textSelection(.enabled)
                Text("烽火 CPE macOS 本地管理工具")
                    .font(Theme.label)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var featuresPanel: some View {
        Panel(padding: Theme.Space.m, spacing: Theme.Space.s) {
            PanelHeading("本地设备管理")
            Text("支持烽火 CPE 设备，RP0106+")
                .font(Theme.footnote)
                .foregroundStyle(Theme.inkSecondary)
            Text("通过本地网络连接 CPE，查看网络与流量、管理在线设备、调整设备设置及收发短信。")
                .font(Theme.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyPanel: some View {
        Panel(padding: Theme.Space.m, spacing: Theme.Space.s) {
            PanelHeading("数据与隐私")
            privacyRow(symbol: "key", title: "密码", detail: "可选择保存至系统钥匙串。")
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            privacyRow(symbol: "message", title: "短信", detail: "仅保存在内存，断开连接后清空。")
        }
    }

    private func privacyRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 16, height: 15)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var versionLabel: String {
        let version = bundleValue("CFBundleShortVersionString")
        return "版本 \(version ?? "1.0-Alpha2")"
    }

    private func bundleValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
