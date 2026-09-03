import Foundation
import SwiftData
import CoreData

enum StoreBootstrap {

    /// Set when the previous store could not be opened and was set aside so the
    /// app could start. The library itself lives on disk as Markdown, so it is
    /// rebuilt by the next scan; only favorites, collections and server entries
    /// are lost, and the old file is kept so it can be recovered.
    @MainActor static var recoveredFromUnreadableStore: URL?

    /// Overrides where the store lives. Tests set this so they never touch the
    /// user's real library index; nil means the standard Application Support
    /// location.
    nonisolated(unsafe) static var containerDirectoryOverride: URL?

    /// True when neither the existing store nor a fresh one could be opened and
    /// the app is running on a throwaway in-memory store. Nothing is saved.
    @MainActor static var runningInMemoryOnly = false

    /// Opens the store, falling back to a fresh one when the existing file is
    /// genuinely unreadable. Crashing on a corrupt store would lock the user out
    /// of the app on every launch with no way back in.
    static func makeContainer(schema: Schema) throws -> ModelContainer {
        do {
            let config = try makeConfiguration(schema: schema)
            return try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            // A transient failure must not cost the user their favorites. Being
            // out of space is the realistic way a healthy store fails to open,
            // and SwiftData reports it the same way as corruption, so check the
            // volume before concluding the file is bad.
            guard indicatesUnreadableStore(error), !isOutOfSpace() else {
                AppLogger.fileIO.error("Could not open the store: \(error.localizedDescription). Leaving it untouched.")
                throw error
            }

            AppLogger.fileIO.error("Store is unreadable: \(error.localizedDescription). Rebuilding it.")
            let quarantined = quarantineStore()

            // Build straight from the store URL rather than re-running the
            // preparation step, whose legacy-store migration is itself a way
            // this can fail — retrying it would just throw again.
            let storeURL = try storeURL(using: FileManager.default)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            if let quarantined {
                Task { @MainActor in recoveredFromUnreadableStore = quarantined }
            }
            return container
        }
    }

    /// Whether the error means the store file cannot be read or migrated, as
    /// opposed to a transient problem where the file is probably fine.
    private static func indicatesUnreadableStore(_ error: Error) -> Bool {
        // SwiftData collapses "could not load this store" into one case,
        // whatever Core Data said underneath.
        if let dataError = error as? SwiftDataError, dataError == .loadIssueModelContainer {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadCorruptFileError,
                 NSPersistentStoreIncompatibleVersionHashError,
                 NSMigrationError,
                 NSMigrationConstraintViolationError,
                 NSMigrationMissingSourceModelError,
                 NSMigrationMissingMappingModelError,
                 NSPersistentStoreIncompatibleSchemaError,
                 NSPersistentStoreInvalidTypeError,
                 NSPersistentStoreOpenError:
                return true
            default:
                break
            }
        }
        // SwiftData wraps the underlying Core Data failure; check it too.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== nsError {
            return indicatesUnreadableStore(underlying)
        }
        return false
    }

    /// Whether the volume holding the store has essentially no room left, in
    /// which case an open failure says nothing about the file's health.
    private static func isOutOfSpace() -> Bool {
        guard let storeURL = try? storeURL(using: FileManager.default),
              let values = try? storeURL.deletingLastPathComponent()
                  .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return false }
        return available < 50_000_000
    }

    /// Moves the unreadable store and its sidecars aside. Returns where the
    /// main file went, or nil if there was nothing to move (a store that never
    /// existed, so there is nothing to tell the user about).
    private static func quarantineStore() -> URL? {
        let fm = FileManager.default
        guard let storeURL = try? storeURL(using: fm) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let directory = storeURL.deletingLastPathComponent()

        // A unique suffix, so a second failure in the same second can't delete
        // the first backup — which may hold the only copy of their collections.
        var quarantineURL = directory.appendingPathComponent("SkillKit-unreadable-\(stamp).store")
        var attempt = 2
        while fm.fileExists(atPath: quarantineURL.path) {
            quarantineURL = directory.appendingPathComponent("SkillKit-unreadable-\(stamp)-\(attempt).store")
            attempt += 1
        }

        var movedMainFile = false
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: quarantineURL.path + suffix)
            do {
                try fm.moveItem(at: source, to: destination)
                if suffix.isEmpty { movedMainFile = true }
            } catch {
                // A sidecar we can't move must not discard the main result; the
                // fresh store would otherwise be built beside a stale -wal.
                AppLogger.fileIO.error("Could not set aside \(source.lastPathComponent): \(error.localizedDescription)")
                try? fm.removeItem(at: source)
            }
        }

        // The legacy store is re-migrated whenever the main one is missing, so
        // leaving a broken one in place would fail the rebuild every launch.
        let legacyURL = directory.appendingPathComponent("default.store")
        if fm.fileExists(atPath: legacyURL.path) {
            let legacyDestination = directory.appendingPathComponent("SkillKit-unreadable-\(stamp)-legacy.store")
            try? fm.moveItem(at: legacyURL, to: legacyDestination)
        }

        guard movedMainFile else { return nil }
        AppLogger.fileIO.notice("Set the unreadable store aside at \(quarantineURL.lastPathComponent)")
        return quarantineURL
    }

    private static func storeURL(using fm: FileManager) throws -> URL {
        try appSupportDirectory(using: fm).appendingPathComponent("SkillKit.store")
    }

    static func makeConfiguration(schema: Schema) throws -> ModelConfiguration {
        let storeURL = try prepareStoreURL(schema: schema)
        return ModelConfiguration(schema: schema, url: storeURL)
    }

    private static func prepareStoreURL(schema: Schema) throws -> URL {
        let fm = FileManager.default
        let appSupportURL = try appSupportDirectory(using: fm)
        let storeURL = appSupportURL.appendingPathComponent("SkillKit.store")

        if !fm.fileExists(atPath: storeURL.path) {
            try? removeStoreFiles(at: storeURL)
            let legacyURL = try legacyStoreURL(using: fm)
            if fm.fileExists(atPath: legacyURL.path) {
                try migrateLegacyStore(from: legacyURL, to: storeURL, schema: schema)
            }
        }

        return storeURL
    }

    private static func appSupportDirectory(using fm: FileManager) throws -> URL {
        if let containerDirectoryOverride {
            try fm.createDirectory(at: containerDirectoryOverride, withIntermediateDirectories: true)
            return containerDirectoryOverride
        }

        guard let baseURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let appSupportURL = baseURL.appendingPathComponent("SkillKit", isDirectory: true)
        try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        return appSupportURL
    }

    private static func legacyStoreURL(using fm: FileManager) throws -> URL {
        if let containerDirectoryOverride {
            return containerDirectoryOverride.appendingPathComponent("default.store")
        }

        guard let baseURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        return baseURL.appendingPathComponent("default.store")
    }

    private static func migrateLegacyStore(from legacyURL: URL, to storeURL: URL, schema: Schema) throws {
        let legacyConfig = ModelConfiguration(schema: schema, url: legacyURL)
        let storeConfig = ModelConfiguration(schema: schema, url: storeURL)

        do {
            let legacyContainer = try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [legacyConfig]
            )
            let legacyContext = ModelContext(legacyContainer)

            let storeContainer = try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [storeConfig]
            )
            let storeContext = ModelContext(storeContainer)

            try copyRemoteServers(from: legacyContext, to: storeContext)
            try copyCollections(from: legacyContext, to: storeContext)
            try copySkills(from: legacyContext, to: storeContext)
            try storeContext.save()
        } catch {
            try? removeStoreFiles(at: storeURL)
            throw error
        }
    }

    private static func copyRemoteServers(from legacyContext: ModelContext, to storeContext: ModelContext) throws {
        let descriptor = FetchDescriptor<RemoteServer>()
        for legacyServer in try legacyContext.fetch(descriptor) {
            let server = RemoteServer(
                label: legacyServer.label,
                host: legacyServer.host,
                port: legacyServer.port,
                username: legacyServer.username,
                skillsBasePath: legacyServer.skillsBasePath
            )
            server.id = legacyServer.id
            server.sshKeyPath = legacyServer.sshKeyPath
            server.lastSyncDate = legacyServer.lastSyncDate
            server.lastSyncError = legacyServer.lastSyncError
            storeContext.insert(server)
        }

        try storeContext.save()
    }

    private static func copyCollections(from legacyContext: ModelContext, to storeContext: ModelContext) throws {
        let descriptor = FetchDescriptor<SkillCollection>()
        for legacyCollection in try legacyContext.fetch(descriptor) {
            let collection = SkillCollection(
                name: legacyCollection.name,
                icon: legacyCollection.icon,
                sortOrder: legacyCollection.sortOrder
            )
            storeContext.insert(collection)
        }

        try storeContext.save()
    }

    private static func copySkills(from legacyContext: ModelContext, to storeContext: ModelContext) throws {
        let remoteServers = try storeContext.fetch(FetchDescriptor<RemoteServer>())
        let collections = try storeContext.fetch(FetchDescriptor<SkillCollection>())

        let serversByID = Dictionary(uniqueKeysWithValues: remoteServers.map { ($0.id, $0) })
        let collectionsByName = Dictionary(uniqueKeysWithValues: collections.map { ($0.name, $0) })

        let descriptor = FetchDescriptor<Skill>()
        for legacySkill in try legacyContext.fetch(descriptor) {
            let skill = Skill(
                filePath: legacySkill.filePath,
                toolSource: legacySkill.toolSource,
                isDirectory: legacySkill.isDirectory,
                name: legacySkill.name,
                skillDescription: legacySkill.skillDescription,
                content: legacySkill.content,
                frontmatter: legacySkill.frontmatter,
                isFavorite: legacySkill.isFavorite,
                lastOpened: legacySkill.lastOpened,
                fileModifiedDate: legacySkill.fileModifiedDate,
                fileSize: legacySkill.fileSize,
                isGlobal: legacySkill.isGlobal,
                resolvedPath: legacySkill.resolvedPath,
                kind: legacySkill.itemKind
            )

            skill.frontmatterData = legacySkill.frontmatterData
            skill.toolSourcesRaw = legacySkill.toolSourcesRaw
            skill.installedPathsData = legacySkill.installedPathsData
            skill.remotePath = legacySkill.remotePath
            skill.remoteServer = legacySkill.remoteServer.flatMap { serversByID[$0.id] }
            skill.collections = legacySkill.collections.compactMap { collectionsByName[$0.name] }

            storeContext.insert(skill)
        }
    }

    private static func removeStoreFiles(at storeURL: URL) throws {
        let fm = FileManager.default
        let siblingURLs = [storeURL, sidecarURL(for: storeURL, suffix: "-shm"), sidecarURL(for: storeURL, suffix: "-wal")]

        for url in siblingURLs where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private static func sidecarURL(for storeURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: storeURL.path + suffix)
    }
}
