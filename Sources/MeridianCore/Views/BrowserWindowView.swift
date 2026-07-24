import AppKit
import OSLog
import SwiftUI
import WebKit

private let browserWindowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MeridianBrowser",
    category: "BrowserWindow"
)

private let sidebarRevealHotZoneWidth: CGFloat = 8

private struct SidebarStaticGlassBackdrop<ClipShape: Shape>: View {
    let shape: ClipShape

    var body: some View {
        SidebarNeutralGlassSystemMaterial(shape: shape)
            .allowsHitTesting(false)
    }
}

private enum BrowserSidebarSizing {
    static let widthStorageKey = "BrowserSidebarWidth"
    static let defaultWidth = 280.0
    static let minimumWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 520
    static let resizeOverlayWidth: CGFloat = 18
    static let resizeHitWidth: CGFloat = 8
    static let accessibilityStep: CGFloat = 16

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}

public struct BrowserWindowView: View {
    @ObservedObject private var store: BrowserStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var webViewState = WebViewState()
    @StateObject private var webViewRegistry = BrowserWebViewRegistry()
    @StateObject private var contentPresentationState = BrowserContentPresentationState()
    @StateObject private var sidebarThemeColorSamplerController = SidebarThemeColorSamplerController()
    @StateObject private var dataStoreProvider = ProfileWebsiteDataStoreProvider()
    @AppStorage(BrowserSidebarSizing.widthStorageKey) private var storedSidebarWidth = BrowserSidebarSizing.defaultWidth
    @State private var sidebarResizeStartWidth: CGFloat?
    @State private var sidebarResizeLiveWidth: CGFloat?
    // Reference-only state is intentional. Live pager colors terminate at a
    // small layer-backed tint treatment and never publish through SwiftUI.
    @State private var sidebarChromeLiveStyleController = SidebarChromeLiveStyleController()
    // The parent must not observe this publisher: only the two tiny fixed-chrome
    // wrappers subscribe, keeping display-rate updates away from tabs and pages.
    @State private var sidebarFixedChromeLiveStyleController = SidebarFixedChromeLiveStyleController()
    @State private var autoPresentedDownloadID: UUID?
    @State private var activityPageIsSelected = false
    @State private var sidebarThemeColorPickerSpaceID: SpaceID?
    @State private var showsProfileIsolationRepairAlert = false
    @Namespace private var passwordPromptGlassNamespace
    private let floatingSidebarInset: CGFloat = 8
    private let floatingSidebarCornerRadius: CGFloat = 12
    private var sidebarVisibilityAnimation: Animation {
        .interpolatingSpring(
            mass: 0.82,
            stiffness: 430,
            damping: 44,
            initialVelocity: 0
        )
    }
    private var sidebarPinnedStateAnimation: Animation {
        .smooth(duration: 0.24, extraBounce: 0)
    }
    private var sidebarWidth: CGFloat {
        sidebarResizeLiveWidth ?? BrowserSidebarSizing.clamped(CGFloat(storedSidebarWidth))
    }
    private var sidebarReservedWidth: CGFloat {
        sidebarWidth
    }

    public init(store: BrowserStore) {
        self.store = store
    }

    public var body: some View {
        browserSurface
            .ignoresSafeArea(.container, edges: ignoredContentSafeAreaEdges)
            .toolbar(removing: .title)
            .toolbarVisibility(.hidden, for: .windowToolbar)
            .background(WindowChromeController())
            .background(
                BrowserKeyboardShortcutMonitor(
                    beginNewTab: { store.beginNewTab() },
                    closeSelectedTab: { store.closeSelectedTab() }
                )
            )
            .background(
                SidebarWindowRevealMonitor(
                    edge: store.sidebarRevealEdge,
                    sidebarIsVisible: store.sidebarIsVisible,
                    sidebarIsLockedOpen: store.sidebarIsLockedOpen,
                    reveal: { store.revealSidebar() }
                )
            )
            .overlay(alignment: .top) {
                WindowDragStrip()
            }
            .onAppear {
                showsProfileIsolationRepairAlert = store.profileIsolationRepairOccurredThisLaunch
            }
            .alert("Profile Isolation Repaired", isPresented: $showsProfileIsolationRepairAlert) {
                Button("Copy Diagnostics") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        store.profileIsolationDiagnostics().redactedText,
                        forType: .string
                    )
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.profileIsolationRepairReport.userMessage ?? "Lumen Browser repaired saved profile assignments before browsing began.")
            }
            .overlay {
                if store.isCommandBarPresented {
                    CommandBarDismissalBackdrop(sidebarExclusion: commandBarBackdropSidebarExclusion) {
                        store.hideCommandBar()
                    }
                    .zIndex(9)
                }
            }
            .overlay {
                if store.isCommandBarPresented {
                    CommandBarFloatingLayer(store: store, webViewState: webViewState)
                        .zIndex(10)
                }
            }
            .overlay(alignment: sidebarThemeColorPickerAlignment) {
                sidebarThemeColorPickerLayer
                    .zIndex(11)
            }
            .overlay {
                if let request = store.pendingPasswordSaveRequest {
                    PasswordSavePromptLayer(
                        request: request,
                        profileName: profileName(for: request.profileID),
                        namespace: passwordPromptGlassNamespace,
                        cancel: { store.cancelPendingPasswordSaveRequest() },
                        save: { _ = store.approvePendingPasswordSaveRequest() }
                    )
                    .zIndex(12)
                }
            }
            .animation(.snappy(duration: 0.16), value: store.isCommandBarPresented)
            .animation(.smooth(duration: 0.18), value: store.pendingPasswordSaveRequest?.id)
            .onAppear {
                normalizeStoredSidebarWidth()
                presentPendingDownloadSavePanelIfNeeded()
            }
            .onChange(of: store.pendingDownloadConfirmation?.id) { _, _ in
                presentPendingDownloadSavePanelIfNeeded()
            }
            .onChange(of: store.spaces.map(\.id)) { _, spaceIDs in
                guard let sidebarThemeColorPickerSpaceID,
                      !spaceIDs.contains(sidebarThemeColorPickerSpaceID) else {
                    return
                }
                closeSidebarThemeColorPicker()
            }
            .alert(
                store.pendingURLConfirmation?.confirmationTitle ?? "Open Link?",
                isPresented: pendingURLConfirmationIsPresented,
                presenting: store.pendingURLConfirmation
            ) { request in
                Button("Cancel", role: .cancel) {
                    store.cancelPendingURLConfirmation()
                }
                Button(request.confirmButtonTitle) {
                    store.approvePendingURLConfirmation { url in
                        NSWorkspace.shared.open(url)
                    }
                }
            } message: { request in
                Text(request.confirmationMessage)
            }
            .alert(
                store.pendingDownloadConfirmation?.confirmationTitle ?? "Download File?",
                isPresented: pendingDownloadConfirmationIsPresented,
                presenting: store.pendingDownloadConfirmation
            ) { request in
                Button("Cancel", role: .cancel) {
                    store.cancelPendingDownloadConfirmation()
                }
                Button(request.confirmButtonTitle) {
                    if store.beginPendingDownloadDestinationSelection() {
                        presentSavePanel(for: request)
                    }
                }
            } message: { request in
                Text(request.confirmationMessage)
            }
            .sheet(item: profileManagementRequestBinding) { request in
                ProfileManagementView(store: store, request: request)
            }
    }

    private var browserSurface: some View {
        GeometryReader { proxy in
            browserSurfaceContent(availableHeight: proxy.size.height)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: sidebarRevealAlignment)
                .clipped()
        }
        .focusedSceneValue(\.browserNavigationCommandContext, browserNavigationCommandContext)
    }

    private var profileManagementRequestBinding: Binding<ProfileManagementRequest?> {
        Binding(
            get: { store.profileManagementRequest },
            set: { request in
                if request == nil {
                    store.dismissProfileManager()
                }
            }
        )
    }

    private func browserSurfaceContent(availableHeight: CGFloat) -> some View {
        ZStack(alignment: sidebarRevealAlignment) {
            browserDetail
                .padding(sidebarPaddingEdge, store.sidebarIsLockedOpen ? sidebarReservedWidth : 0)
                .animation(sidebarPinnedStateAnimation, value: store.sidebarIsLockedOpen)
                .zIndex(0)

            sidebarOverlay(availableHeight: availableHeight)
                .offset(x: sidebarVisibilityOffset)
                .allowsHitTesting(sidebarShouldBeMounted)
                .accessibilityHidden(!sidebarShouldBeMounted)
                .animation(sidebarVisibilityAnimation, value: store.sidebarIsVisible)
                .animation(sidebarPinnedStateAnimation, value: store.sidebarIsLockedOpen)
                .zIndex(2)

            if !sidebarShouldBeMounted {
                SidebarRevealZone {
                    store.revealSidebar()
                }
                .frame(width: sidebarRevealHotZoneWidth)
                .frame(height: max(availableHeight, 0))
                .accessibilityHidden(true)
                .zIndex(3)
            }
        }
    }

    private var browserDetail: some View {
        BrowserContentView(
            store: store,
            webViewState: webViewState,
            presentationState: contentPresentationState,
            webViewRegistry: webViewRegistry,
            dataStoreProvider: dataStoreProvider,
            activityPageIsSelected: $activityPageIsSelected,
            webContentMouseExclusionRegion: webContentMouseExclusionRegion,
            openSidebarThemeColorPicker: { openSidebarThemeColorPicker(for: $0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var sidebarThemeColorPickerLayer: some View {
        if let spaceID = sidebarThemeColorPickerSpaceID,
           let space = store.spaces.first(where: { $0.id == spaceID }) {
            SidebarThemeColorPickerPopover(
                colorHex: space.sidebarAppearance.tintHex(forSpaceColorHex: space.colorHex),
                settings: sidebarThemeColorSettingsBinding(for: spaceID),
                samplerController: sidebarThemeColorSamplerController,
                colorChanged: { colorHex in
                    updateSidebarThemeColor(colorHex, for: spaceID)
                },
                onClose: closeSidebarThemeColorPicker
            )
            .id(spaceID)
            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 14)
            .padding(.top, 56)
            .padding(sidebarThemeColorPickerPaddingEdge, sidebarThemeColorPickerHorizontalPadding)
            .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
        }
    }

    private var sidebarThemeColorPickerAlignment: Alignment {
        switch store.sidebarRevealEdge {
        case .left:
            return .topLeading
        case .right:
            return .topTrailing
        }
    }

    private var sidebarThemeColorPickerPaddingEdge: Edge.Set {
        switch store.sidebarRevealEdge {
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    private var sidebarThemeColorPickerHorizontalPadding: CGFloat {
        sidebarWidth + sidebarOuterInset + 12
    }

    private func sidebarThemeColorSettingsBinding(for spaceID: SpaceID) -> Binding<SidebarGlassSettings> {
        Binding {
            store.spaces.first { $0.id == spaceID }?.sidebarAppearance.base ?? .standard
        } set: { settings in
            guard let space = store.spaces.first(where: { $0.id == spaceID }) else {
                return
            }
            var appearance = space.sidebarAppearance
            appearance.base = settings
            appearance.pinnedOverride = nil
            _ = store.customizeSpace(
                spaceID,
                name: space.name,
                symbolName: space.symbolName,
                colorHex: space.colorHex,
                sidebarAppearance: appearance,
                persistImmediately: false
            )
        }
    }

    private func openSidebarThemeColorPicker(for spaceID: SpaceID) {
        guard store.spaces.contains(where: { $0.id == spaceID }) else {
            return
        }

        if sidebarThemeColorPickerSpaceID != spaceID {
            sidebarThemeColorSamplerController.cancelSampling()
        }

        withAnimation(.smooth(duration: 0.16, extraBounce: 0)) {
            sidebarThemeColorPickerSpaceID = spaceID
        }
    }

    private func closeSidebarThemeColorPicker() {
        sidebarThemeColorSamplerController.cancelSampling()
        withAnimation(.smooth(duration: 0.14, extraBounce: 0)) {
            sidebarThemeColorPickerSpaceID = nil
        }
    }

    private func updateSidebarThemeColor(_ colorHex: String, for spaceID: SpaceID) {
        guard let space = store.spaces.first(where: { $0.id == spaceID }) else {
            return
        }

        var appearance = space.sidebarAppearance
        appearance.tintSource = .custom
        appearance.tintHex = colorHex
        appearance.pinnedOverride = nil
        _ = store.customizeSpace(
            spaceID,
            name: space.name,
            symbolName: space.symbolName,
            colorHex: space.colorHex,
            sidebarAppearance: appearance,
            persistImmediately: false
        )
    }

    private func sidebarOverlay(availableHeight: CGFloat) -> some View {
        sidebarShell(availableHeight: availableHeight)
            .background(
                Group {
                    if store.sidebarIsVisible && !store.sidebarIsLockedOpen {
                        SidebarExitTrackingZone(
                            dismissalIsSuspended: sidebarResizeStartWidth != nil
                        ) {
                            store.hideTransientSidebar()
                        }
                    }
                }
                .accessibilityHidden(true)
            )
    }

    private func sidebarShell(availableHeight: CGFloat) -> some View {
        sidebar
            .frame(width: sidebarWidth, height: sidebarBodyHeight(for: availableHeight))
            .padding(.vertical, sidebarOuterInset)
            .padding(sidebarPaddingEdge, sidebarOuterInset)
    }

    private var sidebar: some View {
        let shape = sidebarShape
        let cornerRadii = sidebarCornerRadii
        let pinnedOpacity = Double(sidebarPinnedProgress)
        let floatingOpacity = Double(sidebarFloatingProgress)
        let contentChromeTheme = selectedSidebarChromeTheme
        let fallbackStyle = SidebarChromeLiveStyle(theme: contentChromeTheme)

        return ZStack {
            SidebarChromeLiveShadowOverlay(
                controller: sidebarChromeLiveStyleController,
                fallbackStyle: fallbackStyle,
                floatingOpacity: floatingOpacity,
                cornerRadii: cornerRadii
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            // The native Liquid Glass surface is intentionally static for the
            // whole gesture. Reconfiguring it at scroll cadence is the expensive
            // path that previously made tab-heavy spaces miss display frames.
            SidebarStaticGlassBackdrop(
                shape: shape
            )

            // Every non-native chrome channel follows the pager in retained
            // layers: tint, density, highlights, texture, and the outer edge.
            SidebarChromeLiveTintOverlay(
                controller: sidebarChromeLiveStyleController,
                fallbackStyle: fallbackStyle,
                pinnedOpacity: pinnedOpacity,
                floatingOpacity: floatingOpacity,
                cornerRadii: cornerRadii
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            SidebarView(
                store: store,
                webViewState: webViewState,
                presentationState: contentPresentationState,
                activityPageIsSelected: $activityPageIsSelected,
                tabHasLiveSession: { webViewRegistry.containsSession(for: $0) },
                fixedChromeLiveStyleController: sidebarFixedChromeLiveStyleController,
                updateSidebarChromeLiveStyle: { sidebarChromeLiveStyleController.update($0) }
            )
            .clipShape(shape)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: sidebarResizeHandleAlignment) { sidebarResizeHandle }
        .accessibilityIdentifier("BrowserSidebar")
    }

    private var selectedSidebarChromeTheme: SidebarChromeTheme {
        guard !activityPageIsSelected else {
            return .standard
        }

        guard let selectedSpace = store.selectedSpace else {
            return .standard
        }

        return SidebarChromeTheme.theme(for: selectedSpace)
    }

    private var sidebarOuterInset: CGFloat {
        store.sidebarIsLockedOpen ? 0 : floatingSidebarInset
    }

    private func sidebarBodyHeight(for availableHeight: CGFloat) -> CGFloat {
        max(0, availableHeight - sidebarOuterInset * 2)
    }

    private var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: sidebarCornerRadii.rectangleCornerRadii, style: .continuous)
    }

    private var sidebarCornerRadii: SidebarChromeCornerRadii {
        SidebarChromeCornerRadii.resolved(
            isPinned: store.sidebarIsLockedOpen,
            edge: store.sidebarRevealEdge,
            radius: floatingSidebarCornerRadius
        )
    }

    private var sidebarPinnedProgress: CGFloat {
        store.sidebarIsLockedOpen ? 1 : 0
    }

    private var sidebarFloatingProgress: CGFloat {
        1 - sidebarPinnedProgress
    }

    private var sidebarResizeHandleAlignment: Alignment {
        switch store.sidebarRevealEdge {
        case .left:
            return .trailing
        case .right:
            return .leading
        }
    }

    private var sidebarResizeHandle: some View {
        SidebarResizeHandle(
            edge: store.sidebarRevealEdge,
            currentWidth: sidebarWidth,
            onResizeBegan: { startWidth in
                sidebarResizeStartWidth = BrowserSidebarSizing.clamped(startWidth)
                sidebarResizeLiveWidth = BrowserSidebarSizing.clamped(startWidth)
            },
            onResizeChanged: { width in
                sidebarResizeLiveWidth = BrowserSidebarSizing.clamped(width)
            },
            onResizeEnded: { width in
                storedSidebarWidth = Double(BrowserSidebarSizing.clamped(width))
                sidebarResizeStartWidth = nil
                sidebarResizeLiveWidth = nil
            }
        )
            .frame(width: BrowserSidebarSizing.resizeOverlayWidth)
            .frame(maxHeight: .infinity)
            .help("Resize sidebar")
            .accessibilityElement()
            .accessibilityLabel("Resize sidebar")
            .accessibilityValue("\(Int(sidebarWidth.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustSidebarWidth(by: BrowserSidebarSizing.accessibilityStep)
                case .decrement:
                    adjustSidebarWidth(by: -BrowserSidebarSizing.accessibilityStep)
                @unknown default:
                    break
                }
            }
            .zIndex(1)
    }

    private func adjustSidebarWidth(by delta: CGFloat) {
        storedSidebarWidth = Double(BrowserSidebarSizing.clamped(sidebarWidth + delta))
        sidebarResizeStartWidth = nil
        sidebarResizeLiveWidth = nil
    }

    private func normalizeStoredSidebarWidth() {
        storedSidebarWidth = Double(BrowserSidebarSizing.clamped(CGFloat(storedSidebarWidth)))
    }

    private var sidebarShouldBeMounted: Bool {
        store.sidebarIsLockedOpen || store.sidebarIsVisible
    }

    private var sidebarVisibilityOffset: CGFloat {
        guard !sidebarShouldBeMounted else {
            return 0
        }

        let hiddenTravel = sidebarWidth + sidebarOuterInset
        switch store.sidebarRevealEdge {
        case .left:
            return -hiddenTravel
        case .right:
            return hiddenTravel
        }
    }

    private var floatingSidebarShouldBlockWebContent: Bool {
        sidebarShouldBeMounted && !store.sidebarIsLockedOpen
    }

    private var webContentMouseExclusionRegion: WebContentMouseExclusionRegion? {
        guard floatingSidebarShouldBlockWebContent else {
            return nil
        }

        return WebContentMouseExclusionRegion(
            edge: store.sidebarRevealEdge,
            width: sidebarWidth,
            inset: sidebarOuterInset,
            cornerRadius: sidebarCornerRadii.maximumRadius
        )
    }

    private var commandBarBackdropSidebarExclusion: CommandBarBackdropSidebarExclusion? {
        guard sidebarShouldBeMounted else {
            return nil
        }

        return CommandBarBackdropSidebarExclusion(
            edge: store.sidebarRevealEdge,
            width: sidebarWidth + sidebarOuterInset
        )
    }

    private var sidebarPaddingEdge: Edge.Set {
        switch store.sidebarRevealEdge {
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    private var sidebarRevealAlignment: Alignment {
        switch store.sidebarRevealEdge {
        case .left:
            return .leading
        case .right:
            return .trailing
        }
    }

    private var ignoredContentSafeAreaEdges: Edge.Set {
        .top
    }

    private var browserNavigationCommandContext: BrowserNavigationCommandContext {
        BrowserNavigationCommandContext(
            canGoBack: webViewState.canGoBack,
            canGoForward: webViewState.canGoForward,
            canReload: commandTargetTab?.content.isWeb == true && commandTargetTab?.url != nil,
            canStopLoading: webViewState.isLoading
        ) { command in
            webViewState.dispatch(command, targetTabID: commandTargetTabID)
        }
    }

    private var commandTargetTabID: TabID? {
        contentPresentationState.activeContentTabID ?? store.selectedTabID
    }

    private var commandTargetTab: BrowserTab? {
        guard let commandTargetTabID else {
            return nil
        }

        return store.tabs.first { $0.id == commandTargetTabID }
    }

    private var pendingURLConfirmationIsPresented: Binding<Bool> {
        Binding {
            store.pendingURLConfirmation != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelPendingURLConfirmation()
            }
        }
    }

    private var pendingDownloadConfirmationIsPresented: Binding<Bool> {
        Binding {
            guard let request = store.pendingDownloadConfirmation,
                  !store.isChoosingDownloadDestination else {
                return false
            }

            return shouldShowDownloadConfirmationAlert(for: request)
        } set: { isPresented in
            if !isPresented {
                store.dismissPendingDownloadConfirmationAlert()
            }
        }
    }

    private func shouldShowDownloadConfirmationAlert(for request: DownloadConfirmationRequest) -> Bool {
        if case .requiresConfirmation = request.risk {
            return true
        }

        return false
    }

    private func presentPendingDownloadSavePanelIfNeeded() {
        guard let request = store.pendingDownloadConfirmation,
              !store.isChoosingDownloadDestination,
              autoPresentedDownloadID != request.id,
              !shouldShowDownloadConfirmationAlert(for: request) else {
            browserWindowLogger.info(
                "download save panel auto-present skipped pending=\(store.pendingDownloadConfirmation != nil, privacy: .public) choosing=\(store.isChoosingDownloadDestination, privacy: .public)"
            )
            return
        }

        autoPresentedDownloadID = request.id
        browserWindowLogger.info("download save panel auto-present begin")
        if store.beginPendingDownloadDestinationSelection() {
            presentSavePanel(for: request)
        } else {
            browserWindowLogger.info("download save panel auto-present beginSelection failed")
        }
    }

    private func presentSavePanel(for request: DownloadConfirmationRequest) {
        let panel = NSSavePanel()
        panel.title = request.confirmationTitle
        panel.nameFieldStringValue = request.sanitizedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        browserWindowLogger.info("download save panel presenting")
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let destinationURL = panel.url else {
                    browserWindowLogger.info("download save panel canceled")
                    store.cancelPendingDownloadConfirmation()
                    return
                }

                browserWindowLogger.info("download save panel approved")
                store.approvePendingDownloadConfirmation(destination: destinationURL)
            }
        }
    }

    private func profileName(for profileID: ProfileID) -> String {
        store.profiles.first { $0.id == profileID }?.name ?? "Unknown Profile"
    }
}

private struct PasswordSavePromptLayer: View {
    let request: PasswordSaveRequest
    let profileName: String
    let namespace: Namespace.ID
    let cancel: () -> Void
    let save: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        ZStack {
            Color.black
                .opacity(colorScheme == .dark ? 0.18 : 0.08)
                .ignoresSafeArea()

            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 48, height: 48)
                            .glassEffect(
                                .regular
                                    .tint(Color.accentColor.opacity(0.16))
                                    .interactive(false),
                                in: Circle()
                            )
                            .glassEffectID("passwordSavePromptIcon", in: namespace)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Save this password?")
                                .font(.title3.weight(.semibold))
                            Text("Store this sign-in locally in your macOS Keychain for autofill in Lumen Browser.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        PasswordSavePromptDetailRow(symbolName: "globe", title: request.displayHost)
                        PasswordSavePromptDetailRow(symbolName: "person.crop.circle", title: request.username)
                        PasswordSavePromptDetailRow(symbolName: "person.2", title: profileName)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                    }

                    HStack(spacing: 10) {
                        Button {
                            cancel()
                        } label: {
                            Label("Not Now", systemImage: "xmark")
                                .frame(minWidth: 106)
                        }
                        .keyboardShortcut(.cancelAction)

                        Spacer(minLength: 0)

                        Button {
                            save()
                        } label: {
                            Label(request.confirmButtonTitle, systemImage: "checkmark")
                                .frame(minWidth: 132)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(22)
                .frame(width: 430)
                .contentShape(shape)
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(0.08))
                        .interactive(false),
                    in: shape
                )
                .glassEffectID("passwordSavePromptSurface", in: namespace)
                .compositingGroup()
            }
            .overlay {
                shape.stroke(.separator.opacity(0.48), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.18), radius: 32, x: 0, y: 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .onExitCommand {
            cancel()
        }
    }
}

private struct PasswordSavePromptDetailRow: View {
    let symbolName: String
    let title: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SidebarWindowRevealMonitor: NSViewRepresentable {
    let edge: SidebarRevealEdge
    let sidebarIsVisible: Bool
    let sidebarIsLockedOpen: Bool
    let reveal: @MainActor () -> Void

    func makeNSView(context: Context) -> SidebarWindowRevealNSView {
        SidebarWindowRevealNSView()
    }

    func updateNSView(_ nsView: SidebarWindowRevealNSView, context: Context) {
        nsView.edge = edge
        nsView.sidebarIsVisible = sidebarIsVisible
        nsView.sidebarIsLockedOpen = sidebarIsLockedOpen
        nsView.reveal = reveal
        nsView.window?.acceptsMouseMovedEvents = true
        nsView.syncPointerObservation()
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    let edge: SidebarRevealEdge
    let currentWidth: CGFloat
    let onResizeBegan: (CGFloat) -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizeNSView {
        SidebarResizeNSView()
    }

    func updateNSView(_ nsView: SidebarResizeNSView, context: Context) {
        nsView.edge = edge
        nsView.currentWidth = currentWidth
        nsView.onResizeBegan = onResizeBegan
        nsView.onResizeChanged = onResizeChanged
        nsView.onResizeEnded = onResizeEnded
    }
}

private final class SidebarResizeNSView: NSView {
    var edge: SidebarRevealEdge = .left {
        didSet {
            if edge != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var currentWidth: CGFloat = BrowserSidebarSizing.defaultWidth
    var onResizeBegan: ((CGFloat) -> Void)?
    var onResizeChanged: ((CGFloat) -> Void)?
    var onResizeEnded: ((CGFloat) -> Void)?

    private var dragStartX: CGFloat?
    private var dragStartWidth: CGFloat?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        if dragStartX != nil || activeRect.contains(point) {
            return self
        }

        return nil
    }

    override func resetCursorRects() {
        addCursorRect(activeRect, cursor: .resizeLeftRight)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            finishResize(at: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth
        onResizeBegan?(currentWidth)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let nextWidth = resizedWidth(at: event.locationInWindow.x) else {
            return
        }

        onResizeChanged?(nextWidth)
    }

    override func mouseUp(with event: NSEvent) {
        finishResize(at: event.locationInWindow.x)
    }

    private var activeRect: CGRect {
        let width = min(BrowserSidebarSizing.resizeHitWidth, bounds.width)
        switch edge {
        case .left:
            return CGRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
        case .right:
            return CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        }
    }

    private func resizedWidth(at windowX: CGFloat) -> CGFloat? {
        guard let dragStartX, let dragStartWidth else {
            return nil
        }

        let delta = switch edge {
        case .left:
            windowX - dragStartX
        case .right:
            dragStartX - windowX
        }

        return BrowserSidebarSizing.clamped(dragStartWidth + delta)
    }

    private func finishResize(at windowX: CGFloat?) {
        let finalWidth = windowX.flatMap(resizedWidth(at:)) ?? currentWidth
        if dragStartX != nil {
            onResizeEnded?(finalWidth)
        }
        dragStartX = nil
        dragStartWidth = nil
    }
}

private final class SidebarWindowRevealNSView: NSView {
    var edge: SidebarRevealEdge = .left
    var sidebarIsVisible = true {
        didSet {
            if !sidebarIsVisible {
                revealIsPending = false
            }
            syncPointerObservation()
        }
    }
    var sidebarIsLockedOpen = true {
        didSet {
            syncPointerObservation()
        }
    }
    var reveal: (@MainActor () -> Void)?

    private var pointerTimer: Timer?
    private var eventMonitor: Any?
    private var revealIsPending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        syncPointerObservation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopPointerTimer()
            removeEventMonitor()
        }
    }

    func syncPointerObservation() {
        guard window != nil,
              !sidebarIsLockedOpen,
              !sidebarIsVisible else {
            stopPointerTimer()
            removeEventMonitor()
            return
        }

        startPointerTimerIfNeeded()
        installEventMonitorIfNeeded()
    }

    private func startPointerTimerIfNeeded() {
        guard pointerTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.revealIfPointerIsAtWindowEdge()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window else {
            return
        }

        revealIfPointerIsAtWindowEdge()
    }

    private func revealIfPointerIsAtWindowEdge() {
        guard !sidebarIsLockedOpen,
              !sidebarIsVisible,
              !revealIsPending,
              let window else {
            return
        }

        guard let contentView = window.contentView else {
            return
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        if contentPoint.isAt(edge: edge, width: sidebarRevealHotZoneWidth, in: contentView.bounds) {
            triggerReveal()
        }
    }

    private func triggerReveal() {
        guard !revealIsPending else {
            return
        }

        revealIsPending = true
        Task { @MainActor [weak self] in
            self?.reveal?()
            try? await Task.sleep(nanoseconds: 120_000_000)
            if self?.sidebarIsVisible == false {
                self?.revealIsPending = false
            }
        }
    }
}

private struct SidebarRevealZone: NSViewRepresentable {
    let reveal: @MainActor () -> Void

    func makeNSView(context: Context) -> SidebarRevealTrackingNSView {
        SidebarRevealTrackingNSView()
    }

    func updateNSView(_ nsView: SidebarRevealTrackingNSView, context: Context) {
        nsView.reveal = reveal
        nsView.startPointerTimerIfNeeded()
    }
}

private struct SidebarExitTrackingZone: NSViewRepresentable {
    let dismissalIsSuspended: Bool
    let dismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> SidebarExitTrackingNSView {
        SidebarExitTrackingNSView()
    }

    func updateNSView(_ nsView: SidebarExitTrackingNSView, context: Context) {
        nsView.dismissalIsSuspended = dismissalIsSuspended
        nsView.dismiss = dismiss
        nsView.startPointerTimerIfNeeded()
    }
}

private struct SidebarHitTestShield: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> SidebarHitTestShieldNSView {
        SidebarHitTestShieldNSView()
    }

    func updateNSView(_ nsView: SidebarHitTestShieldNSView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.window?.acceptsMouseMovedEvents = true
        nsView.installEventMonitorIfNeeded()
    }
}

final class SidebarHitTestShieldNSView: NSView {
    private var hoverTrackingArea: NSTrackingArea?
    private var eventMonitor: Any?

    var cornerRadius: CGFloat = 0 {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installEventMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        removeEventMonitor()
    }

    deinit {
        MainActor.assumeIsolated {
            removeEventMonitor()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitRegionContains(point) else {
            return nil
        }

        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseDragged,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseDragged,
            .otherMouseUp,
            .mouseMoved,
            .scrollWheel,
            .cursorUpdate
        ]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func hitRegionContains(_ point: NSPoint) -> Bool {
        guard bounds.contains(point) else {
            return false
        }

        guard cornerRadius > 0 else {
            return true
        }

        return NSBezierPath(
            roundedRect: bounds,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        .contains(point)
    }

    func shouldSuppressWebContentEvent(localPoint: NSPoint, targetView: NSView?) -> Bool {
        hitRegionContains(localPoint) && targetView.map(Self.viewBelongsToWebContent) == true
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else {
            return event
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        guard hitRegionContains(localPoint) else {
            return event
        }

        NSCursor.arrow.set()

        let targetView = eventTarget(in: window, at: event.locationInWindow)
        return shouldSuppressWebContentEvent(localPoint: localPoint, targetView: targetView) ? nil : event
    }

    private func eventTarget(in window: NSWindow, at windowPoint: NSPoint) -> NSView? {
        guard let contentView = window.contentView else {
            return nil
        }

        return contentView.hitTest(contentView.convert(windowPoint, from: nil))
    }

    private static func viewBelongsToWebContent(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is WKWebView {
                return true
            }
            candidate = current.superview
        }

        return false
    }
}

private final class SidebarRevealTrackingNSView: NSView {
    var reveal: (@MainActor () -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerTimer: Timer?
    private var revealIsPending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        startPointerTimerIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopPointerTimer()
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        triggerReveal()
    }

    override func mouseMoved(with event: NSEvent) {
        triggerReveal()
    }

    override func mouseDragged(with event: NSEvent) {
        triggerReveal()
    }

    override func mouseDown(with event: NSEvent) {
        triggerReveal()
    }

    func startPointerTimerIfNeeded() {
        guard pointerTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRevealIfPointerIsInside()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func triggerRevealIfPointerIsInside() {
        guard let window else {
            return
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        if bounds.contains(localPoint) {
            triggerReveal()
        }
    }

    private func triggerReveal() {
        guard !revealIsPending else {
            return
        }

        revealIsPending = true
        Task { @MainActor [weak self] in
            self?.reveal?()
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.revealIsPending = false
        }
    }
}

private final class SidebarExitTrackingNSView: NSView {
    var dismiss: (@MainActor () -> Void)?
    var dismissalIsSuspended = false {
        didSet {
            if dismissalIsSuspended {
                outsideStartDate = nil
            }
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerTimer: Timer?
    private var outsideStartDate: Date?
    private let dismissalDelay: TimeInterval = 0.22
    private let boundsTolerance: CGFloat = 24

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        startPointerTimerIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopPointerTimer()
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseExited(with event: NSEvent) {
        updateDismissalState()
    }

    override func mouseMoved(with event: NSEvent) {
        updateDismissalState()
    }

    func startPointerTimerIfNeeded() {
        guard pointerTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDismissalState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    private func updateDismissalState() {
        guard !dismissalIsSuspended else {
            outsideStartDate = nil
            return
        }

        guard let window else {
            return
        }

        let windowBounds = convert(bounds, to: nil)
        let screenBounds = window.convertToScreen(windowBounds)
        let protectedBounds = screenBounds.insetBy(dx: -boundsTolerance, dy: -boundsTolerance)

        if protectedBounds.contains(NSEvent.mouseLocation) {
            outsideStartDate = nil
            return
        }

        let now = Date()
        if let outsideStartDate {
            if now.timeIntervalSince(outsideStartDate) >= dismissalDelay {
                self.outsideStartDate = nil
                triggerDismiss()
            }
        } else {
            outsideStartDate = now
        }
    }

    private func triggerDismiss() {
        Task { @MainActor in dismiss?() }
    }
}

private extension NSPoint {
    func isAt(edge: SidebarRevealEdge, width: CGFloat, in bounds: CGRect) -> Bool {
        switch edge {
        case .left:
            return x >= bounds.minX && x <= bounds.minX + width
        case .right:
            return x <= bounds.maxX && x >= bounds.maxX - width
        }
    }
}

private struct WindowDragStrip: View {
    var body: some View {
        WindowTitlebarInteractionZone()
            .frame(height: 8)
            .accessibilityHidden(true)
    }
}

struct CommandBarPlacement: Equatable {
    static let originXKey = "CommandBarOriginX"
    static let originYKey = "CommandBarOriginY"
    static let unsetCoordinate = -1.0
    static let margin: CGFloat = 12
    static let defaultTopMargin: CGFloat = 24
    static let boundingSize = CGSize(width: CommandBarMetrics.width, height: CommandBarMetrics.maximumHeight)

    static func resolvedOrigin(
        persistedX: Double,
        persistedY: Double,
        containerSize: CGSize
    ) -> CGPoint {
        let candidate: CGPoint
        if persistedX >= 0, persistedY >= 0, persistedX.isFinite, persistedY.isFinite {
            candidate = CGPoint(x: persistedX, y: persistedY)
        } else {
            candidate = defaultOrigin(containerSize: containerSize)
        }

        return clampedOrigin(candidate, itemSize: boundingSize, containerSize: containerSize)
    }

    static func defaultOrigin(containerSize: CGSize) -> CGPoint {
        CGPoint(
            x: max(margin, (containerSize.width - boundingSize.width) / 2),
            y: defaultTopMargin
        )
    }

    static func clampedOrigin(
        _ origin: CGPoint,
        itemSize: CGSize,
        containerSize: CGSize,
        margin: CGFloat = margin
    ) -> CGPoint {
        CGPoint(
            x: clampedCoordinate(origin.x, itemLength: itemSize.width, containerLength: containerSize.width, margin: margin),
            y: clampedCoordinate(origin.y, itemLength: itemSize.height, containerLength: containerSize.height, margin: margin)
        )
    }

    static func containerID(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    private static func clampedCoordinate(
        _ value: CGFloat,
        itemLength: CGFloat,
        containerLength: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        guard containerLength > itemLength + margin * 2 else {
            return max(0, (containerLength - itemLength) / 2)
        }

        return min(max(value, margin), containerLength - itemLength - margin)
    }
}

private struct CommandBarFloatingLayer: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var webViewState: WebViewState
    @AppStorage(CommandBarPlacement.originXKey) private var persistedOriginX = CommandBarPlacement.unsetCoordinate
    @AppStorage(CommandBarPlacement.originYKey) private var persistedOriginY = CommandBarPlacement.unsetCoordinate
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let origin = CommandBarPlacement.resolvedOrigin(
                persistedX: persistedOriginX,
                persistedY: persistedOriginY,
                containerSize: containerSize
            )

            ZStack(alignment: .topLeading) {
                CommandBarView(store: store, webViewState: webViewState)
                    .offset(x: origin.x, y: origin.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .simultaneousGesture(dragGesture(currentOrigin: origin, containerSize: containerSize))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: CommandBarPlacement.containerID(containerSize)) {
                persist(origin)
            }
        }
    }

    private func dragGesture(currentOrigin: CGPoint, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStartOrigin == nil {
                    dragStartOrigin = currentOrigin
                }

                let startOrigin = dragStartOrigin ?? currentOrigin
                let candidate = CGPoint(
                    x: startOrigin.x + value.translation.width,
                    y: startOrigin.y + value.translation.height
                )
                persist(CommandBarPlacement.clampedOrigin(
                    candidate,
                    itemSize: CommandBarPlacement.boundingSize,
                    containerSize: containerSize
                ))
            }
            .onEnded { _ in
                dragStartOrigin = nil
            }
    }

    private func persist(_ origin: CGPoint) {
        persistedOriginX = origin.x
        persistedOriginY = origin.y
    }
}

private struct BrowserKeyboardShortcutMonitor: NSViewRepresentable {
    let beginNewTab: @MainActor () -> Void
    let closeSelectedTab: @MainActor () -> Void

    func makeNSView(context: Context) -> BrowserKeyboardShortcutMonitorNSView {
        let nsView = BrowserKeyboardShortcutMonitorNSView()
        nsView.beginNewTab = beginNewTab
        nsView.closeSelectedTab = closeSelectedTab
        return nsView
    }

    func updateNSView(_ nsView: BrowserKeyboardShortcutMonitorNSView, context: Context) {
        nsView.beginNewTab = beginNewTab
        nsView.closeSelectedTab = closeSelectedTab
        nsView.installEventMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: BrowserKeyboardShortcutMonitorNSView, coordinator: ()) {
        nsView.removeEventMonitor()
    }
}

private final class BrowserKeyboardShortcutMonitorNSView: NSView {
    var beginNewTab: (@MainActor () -> Void)?
    var closeSelectedTab: (@MainActor () -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installEventMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeEventMonitor()
        }
    }

    func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else {
                return event
            }

            if event.isCommandT {
                Task { @MainActor in
                    self.beginNewTab?()
                }
                return nil
            }

            if event.isCommandW {
                Task { @MainActor in
                    self.closeSelectedTab?()
                }
                return nil
            }

            return event
        }
    }

    func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private struct CommandBarBackdropSidebarExclusion {
    let edge: SidebarRevealEdge
    let width: CGFloat
}

private struct CommandBarDismissalBackdrop: View {
    let sidebarExclusion: CommandBarBackdropSidebarExclusion?
    let dismiss: @MainActor () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if sidebarExclusion?.edge == .left {
                    sidebarPassthrough(width: sidebarExclusionWidth(in: proxy.size))
                }

                dismissalRegion

                if sidebarExclusion?.edge == .right {
                    sidebarPassthrough(width: sidebarExclusionWidth(in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background {
                CommandBarEscapeKeyMonitor(dismiss: dismiss)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        }
    }

    private var dismissalRegion: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                dismiss()
            }
    }

    private func sidebarPassthrough(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .allowsHitTesting(false)
    }

    private func sidebarExclusionWidth(in size: CGSize) -> CGFloat {
        guard let sidebarExclusion else {
            return 0
        }
        return min(max(sidebarExclusion.width, 0), max(size.width, 0))
    }
}

private struct CommandBarEscapeKeyMonitor: NSViewRepresentable {
    let dismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> CommandBarEscapeKeyMonitorNSView {
        let nsView = CommandBarEscapeKeyMonitorNSView()
        nsView.dismiss = dismiss
        return nsView
    }

    func updateNSView(_ nsView: CommandBarEscapeKeyMonitorNSView, context: Context) {
        nsView.dismiss = dismiss
        nsView.installEventMonitorIfNeeded()
    }

    static func dismantleNSView(_ nsView: CommandBarEscapeKeyMonitorNSView, coordinator: ()) {
        nsView.removeEventMonitor()
    }
}

private final class CommandBarEscapeKeyMonitorNSView: NSView {
    var dismiss: (@MainActor () -> Void)?
    private var eventMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installEventMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeEventMonitor()
        }
    }

    func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else {
            return
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.isEscapeKey else {
                return event
            }

            Task { @MainActor in
                self.dismiss?()
            }
            return nil
        }
    }

    func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private extension NSEvent {
    var isCommandT: Bool {
        charactersIgnoringModifiers?.lowercased() == "t"
            && modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.control)
    }

    var isCommandW: Bool {
        charactersIgnoringModifiers?.lowercased() == "w"
            && modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.control)
    }

    var isEscapeKey: Bool {
        keyCode == 53 || charactersIgnoringModifiers == "\u{1B}"
    }
}

private struct WindowChromeController: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.applyMeridianChrome()
        }
    }
}

private extension NSWindow {
    func applyMeridianChrome() {
        title = "Lumen Browser"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior.insert(.fullScreenPrimary)

        setStandardWindowButtonsHidden(true)
        removeMeridianContentCornerOverrides()
        invalidateShadow()
    }

    func setStandardWindowButtonsHidden(_ isHidden: Bool) {
        standardWindowButton(.closeButton)?.isHidden = isHidden
        standardWindowButton(.miniaturizeButton)?.isHidden = isHidden
        standardWindowButton(.zoomButton)?.isHidden = isHidden
    }

    func removeMeridianContentCornerOverrides() {
        guard let contentView else {
            return
        }

        [contentView.superview, contentView].compactMap(\.self).forEach { view in
            view.layer?.cornerRadius = 0
            view.layer?.borderWidth = 0
            view.layer?.masksToBounds = false
        }
    }
}
