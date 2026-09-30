//
//  MenuBarLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var itemManager: MenuBarItemManager

    private var hasItems: Bool {
        !itemManager.itemCache.managedItems.isEmpty
    }

    var body: some View {
        if !ScreenCapture.cachedCheckPermissions() {
            missingScreenRecordingPermissions
        } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
            cannotArrange
        } else {
            IceForm(spacing: 20) {
                header
                layoutBars
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        IceSection {
            Text("拖动图标调整位置")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 20) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
        .opacity(hasItems ? 1 : 0.75)
        .blur(radius: hasItems ? 0 : 5)
        .allowsHitTesting(hasItems)
        .overlay {
            if !hasItems {
                loadingMenuBarItems
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("请先在系统设置中关闭菜单栏自动隐藏")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermissions: some View {
        VStack {
            Text("请为拾一开启屏幕录制权限")
                .font(.title2)

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
                appState.openWindow(.settings)
            } label: {
                Text("打开拾一设置")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var loadingMenuBarItems: some View {
        VStack {
            Text("正在读取图标…")
            ProgressView()
        }
        .font(.title)
    }

    @ViewBuilder
    private func layoutBar(for name: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: name),
            section.isEnabled
        {
            VStack(alignment: .leading) {
                Text(name == .visible ? "常驻" : name == .hidden ? "隐藏" : "始终隐藏")
                    .font(.headline)
                    .padding(.leading, 8)

                LayoutBar(imageCache: appState.imageCache, section: name)
            }
        }
    }
}
