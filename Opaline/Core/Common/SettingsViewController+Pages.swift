import UIKit

// MARK: - Page structure
//
// The settings tree: a root page of category rows, each pushing the same
// view controller with a different `page`. Rows, cells and pickers are
// shared — only the section layout differs per page.

extension SettingsViewController {
    /// A table rather than a switch: it is a straight mapping, and one
    /// entry per page keeps the lint-visible complexity flat as pages are
    /// added.
    private static let pageTitleKeys: [Page: String] = [
        .root: "settings.title",
        .appearance: "settings.section.appearance",
        .language: "settings.section.language",
        .playback: "settings.section.playback",
        .credits: "Credits",
        .creditsOpaline: "Opaline",
        .sponsorBlock: "settings.section.sponsorblock",
        .cache: "settings.section.cache",
        .debug: "settings.section.debug",
        .downloads: "settings.section.downloads"
    ]

    private static let rowPages: [Row: Page] = [
        .pageAppearance: .appearance,
        .pageLanguage: .language,
        .pagePlayback: .playback,
        .pageCredits: .credits,
        .pageCreditsOpaline: .creditsOpaline,
        .pageSponsorBlock: .sponsorBlock,
        .pageCache: .cache,
        .pageDownloads: .downloads,
        .pageDebug: .debug
    ]

    var pageTitle: String { Self.title(for: page) }

    var sections: [Section] {
        switch page {
        case .root:
            return rootSections
        case .appearance:
            return appearanceSections
        case .language:
            return languageSections
        case .playback:
            return playbackSections
        case .credits:
            return creditsSections
        case .creditsOpaline:
            return creditsOpalineSections
        case .sponsorBlock:
            return sponsorBlockSections
        case .cache:
            return cacheSections
        case .debug:
            return debugSections
        case .downloads:
            return downloadsSections
        }
    }

    /// Category rows push a child page.
    private var rootSections: [Section] {
        var sections = [
            Section(
                header: nil,
                footer: nil,
                rows: [
                    .pageAppearance, .pageLanguage,
                    .pagePlayback, .pageDownloads,
                    .pageSponsorBlock,
                    .pageCache, .pageDebug
                ]
            ),
            Section(
                header: nil,
                footer: nil,
                rows: [.pageCredits]
            ),
            Section(
                header: "settings.section.about".localized,
                footer: "settings.footer.about".localized,
                rows: [.aboutVersion, .aboutSystem, .aboutModel]
            )
        ]
        if OpalineImportPrompt.isAvailable {
            sections.insert(
                Section(
                    header: nil,
                    footer: "Settings, sign-ins, music and downloads from Opaline on this iPhone.",
                    rows: [.importOpaline]
                ),
                at: 1
            )
        }
        return sections
    }

    private var appearanceSections: [Section] {
        var themeRows: [Row] = [.theme]
        if showsAutoHours {
            themeRows.append(contentsOf: [.autoDarkStart, .autoDarkEnd])
        }
        return [
            Section(header: nil, footer: themeFooter, rows: themeRows + [.appIcon]),
            Section(
                header: "settings.section.home".localized,
                footer: "settings.footer.home".localized,
                rows: [.homeLayout, .defaultTab]
            ),
            Section(
                header: nil,
                footer: "settings.footer.thumbnailQuality".localized,
                rows: [.thumbnailQuality]
            )
        ]
    }

    private var downloadsSections: [Section] {
        [
            Section(
                header: nil,
                footer: "settings.footer.downloads".localized,
                rows: [.downloadQuality, .downloadComments, .downloadCaptions]
            )
        ]
    }

    private var languageSections: [Section] {
        [
            Section(
                header: nil,
                footer: "settings.footer.language".localized,
                rows: [.region]
            )
        ]
    }

    private var playbackSections: [Section] {
        [
            Section(
                header: "settings.section.videoQuality".localized,
                footer: nil,
                rows: [.quality, .qualityCellular]
            ),
            Section(
                header: nil,
                footer: "settings.footer.playback".localized,
                rows: [
                    .backgroundPlayback, .pipEnabled,
                    .autoZoomToFill, .hideStatusBar,
                    .autoplayEnabled, .autoplayMixEnabled
                ]
            )
        ]
    }

    /// The projects this fork is built on, each with its own page.
    private var creditsSections: [Section] {
        [Section(header: nil, footer: "Girasol is built on the projects above.", rows: [.pageCreditsOpaline])]
    }

    /// The original app and its author: where to find it, and supporting
    /// its development. This fork's own problems are not theirs to field,
    /// so there is no feedback row.
    private var creditsOpalineSections: [Section] {
        [
            Section(
                header: nil,
                footer: "Opaline, the YouTube client for older iOS this app is built on, by verback2308.",
                rows: [.creditsOpalineRepo, .support]
            )
        ]
    }

    private var sponsorBlockSections: [Section] {
        var rows: [Row] = [.sponsorBlockEnabled]
        if SponsorBlockService.enabled {
            rows.append(.sponsorBlockSettings)
        }
        return [
            Section(
                header: nil,
                footer: SponsorBlockService.enabled
                    ? SponsorBlockService.attributionText
                    : nil,
                rows: rows
            )
        ]
    }

    private var cacheSections: [Section] {
        var rows: [Row] = [.persistCache]
        if AppCache.persistenceEnabled {
            rows.append(.feedCacheDays)
        }
        rows.append(.imageCacheEnabled)
        if ThumbnailImageView.cachingEnabled {
            rows.append(.imageCacheDays)
        }
        rows.append(.clearCache)
        return [Section(header: nil, footer: nil, rows: rows)]
    }

    private var debugSections: [Section] {
        var rows: [Row] = [.playbackChain]
        rows.append(contentsOf: [
            .resetIdentity, .solverEndpoint, .mainThreadWatchdog, .shareLog
        ])
        return [
            Section(
                header: nil,
                footer: "settings.footer.debug".localized,
                rows: rows
            )
        ]
    }

    // MARK: Category rows

    static func title(for page: Page) -> String {
        (pageTitleKeys[page] ?? "settings.title").localized
    }

    func makePageCell(_ row: Row) -> UITableViewCell? {
        guard let page = childPage(row) else {
            return nil
        }
        return makeDisclosureCell(Self.title(for: page))
    }

    func handlePageSelection(_ row: Row) -> Bool {
        guard let page = childPage(row) else {
            return false
        }
        navigationController?.pushViewController(
            SettingsViewController(page: page),
            animated: true
        )
        return true
    }

    private func childPage(_ row: Row) -> Page? {
        Self.rowPages[row]
    }
}
