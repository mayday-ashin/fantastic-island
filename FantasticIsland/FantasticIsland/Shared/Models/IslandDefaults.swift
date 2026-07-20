import Foundation

enum IslandDefaults {
    static let audioMutedKey = "island.audioMuted"
    static let fanSoundEnabledKey = "island.settings.fan.soundEnabled"
    static let collapsedSummaryVisibleIDsKey = "island.collapsedSummary.visibleIDs"
    static let launchAtLoginKey = "island.settings.launchAtLogin"
    static let interfaceLanguageKey = "island.settings.interfaceLanguage"
    static let windDriveLogoPresetKey = "island.settings.windDrive.logoPreset"
    static let windDriveUsesCustomLogoKey = "island.settings.windDrive.usesCustomLogo"
    static let windDriveCustomLogoPathKey = "island.settings.windDrive.customLogoPath"
    static let enabledModuleIDsKey = "island.settings.enabledModuleIDs"
    static let fanModuleDefaultEnabledMigrationKey = "island.settings.fanModule.defaultEnabledMigration"
    static let closedWidthAdjustmentKey = "island.settings.layout.closedWidthAdjustment"
    static let closedHeightAdjustmentKey = "island.settings.layout.closedHeightAdjustment"
    static let expandedWidthAdjustmentKey = "island.settings.layout.expandedWidthAdjustment"
    static let expandedHeightAdjustmentKey = "island.settings.layout.expandedHeightAdjustment"
    static let playerTrackSwitchPopupEnabledKey = "island.settings.player.trackSwitchPopupEnabled"
    static let codexStartupRecentConversationPopupEnabledKey = "island.settings.codex.startupRecentConversationPopupEnabled"
    static let codexStandardConversationCardHeightKey = "island.settings.codex.standardConversationCardHeight"
    static let expansionTriggerModeKey = "island.settings.interaction.expansionTriggerMode"
    static let collapseTriggerModeKey = "island.settings.interaction.collapseTriggerMode"
    static let hoverExpansionDelayKey = "island.settings.interaction.hoverExpansionDelay"
    static let expandedAutoCollapseDelayKey = "island.settings.interaction.expandedAutoCollapseDelay"

    // Legacy layout suite retained only for migration and downgrade
    // compatibility. New writes use UserDefaults.standard together with the
    // rest of the application's settings.
    static let layoutSettingsSuiteName = "io.github.fantasticisland.layout"

    private static let legacyAudioMutedKey = "audioMuted"

    /// The single durable settings domain used by Fantastic Island.
    /// UserDefaults writes to the app's preference plist and survives both
    /// application relaunches and macOS restarts.
    static let defaults = UserDefaults.standard

    static func migrateLegacyValues() {
        let defaults = Self.defaults

        if defaults.object(forKey: audioMutedKey) == nil,
           defaults.object(forKey: legacyAudioMutedKey) != nil {
            defaults.set(defaults.bool(forKey: legacyAudioMutedKey), forKey: audioMutedKey)
        }

        // Keep the Fan setting in a positively named, durable key while
        // retaining compatibility with the older inverted audioMuted value.
        if defaults.object(forKey: fanSoundEnabledKey) == nil {
            if defaults.object(forKey: audioMutedKey) != nil {
                defaults.set(!defaults.bool(forKey: audioMutedKey), forKey: fanSoundEnabledKey)
            } else {
                defaults.set(true, forKey: fanSoundEnabledKey)
            }
        }

        // Layout settings used to be written to a separate suite.  The rest
        // of Fantastic Island uses the app's standard defaults domain, so
        // copy the old values into that domain before the app reads them.
        migrateLayoutValues(from: layoutSettingsDefaults, to: defaults)
        defaults.synchronize()
    }

    static var layoutSettingsDefaults: UserDefaults {
        UserDefaults(suiteName: layoutSettingsSuiteName) ?? UserDefaults.standard
    }

    static func migrateLayoutValues(from source: UserDefaults, to destination: UserDefaults) {
        let keys = [
            closedWidthAdjustmentKey,
            closedHeightAdjustmentKey,
            expandedWidthAdjustmentKey,
            expandedHeightAdjustmentKey,
        ]

        for key in keys where destination.object(forKey: key) == nil {
            if let value = source.object(forKey: key) {
                destination.set(value, forKey: key)
            }
        }

        destination.synchronize()
    }
}

enum IslandInterfaceLanguage: String, CaseIterable, Identifiable {
    case followSystem
    case english
    case simplifiedChinese
    case traditionalChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .followSystem:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .followSystem:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .traditionalChinese:
            return "zh-Hant"
        }
    }
}

enum IslandExpansionTriggerMode: String, CaseIterable, Identifiable {
    case click
    case hover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click:
            return "Click"
        case .hover:
            return "Hover"
        }
    }

    var detail: String {
        switch self {
        case .click:
            return "Click the collapsed island to expand it."
        case .hover:
            return "Keep the pointer over the collapsed island to expand it."
        }
    }
}

enum IslandCollapseTriggerMode: String, CaseIterable, Identifiable {
    case clickOutside
    case mouseLeave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clickOutside:
            return "Click Outside"
        case .mouseLeave:
            return "Mouse Leave"
        }
    }

    var detail: String {
        switch self {
        case .clickOutside:
            return "Keep the island open until you click outside it."
        case .mouseLeave:
            return "Automatically close it after the pointer leaves."
        }
    }
}

enum WindDriveLogoPreset: String, CaseIterable, Identifiable {
    case defaultMark
    case appleTV
    case appleTerminal
    case terminal
    case network
    case shield
    case treadmill
    case barre
    case outdoorCycle
    case openWaterSwim
    case tortoise
    case ladybug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultMark:
            return "Apple"
        case .appleTV:
            return "Apple TV"
        case .appleTerminal:
            return "Apple Terminal"
        case .terminal:
            return "Intelligence"
        case .network:
            return "Gamepad"
        case .shield:
            return "Sparkles"
        case .treadmill:
            return "Treadmill"
        case .barre:
            return "Barre"
        case .outdoorCycle:
            return "Outdoor Cycle"
        case .openWaterSwim:
            return "Open Water Swim"
        case .tortoise:
            return "Tortoise"
        case .ladybug:
            return "Ladybug"
        }
    }

    var symbolName: String? {
        switch self {
        case .defaultMark:
            return "apple.logo"
        case .appleTV:
            return "appletv.fill"
        case .appleTerminal:
            return "apple.terminal.fill"
        case .terminal:
            return "apple.intelligence"
        case .network:
            return "gamecontroller.fill"
        case .shield:
            return "hands.and.sparkles.fill"
        case .treadmill:
            return "figure.walk.treadmill"
        case .barre:
            return "figure.barre"
        case .outdoorCycle:
            return "figure.outdoor.cycle"
        case .openWaterSwim:
            return "figure.open.water.swim"
        case .tortoise:
            return "tortoise.fill"
        case .ladybug:
            return "ladybug.fill"
        }
    }
}
