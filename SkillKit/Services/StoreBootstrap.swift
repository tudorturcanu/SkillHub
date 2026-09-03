import Foundation
import SwiftData

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

    /// Opens the store, falling back to a fresh one if the existing file cannot
    /// be opened or migrated. Crashing on a corrupt store would lock the user
    /// out of the app on every launch with no way back in.
    static func makeContainer(schema: Schema) throws -> ModelContainer {
        do {
            let config = try makeConfiguration(schema: schema)
            return try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            AppLogger.fileIO.error("Could not open the store: \(error.localizedDescription). Starting a fresh one.")

            let quarantined = try? quarantineStore()
            let config = try makeConfiguration(schema: schema)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [config]
            )
            if let quarantined {
                Task { @MainActor in recoveredFromUnreadableStore = quarantined }
            }
            return container
        }
    }

    /// Moves the unreadable store (and its -shm/-wal sidecars) aside, returning
    /// where they went.
    private static func quarantineStore() throws -> URL {
        let fm = FileManager.default
        let storeURL = try appSupportDirectory(using: fm).appendingPathComponent("SkillKit.store")
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let quarantineURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("SkillKit-unreadable-\(stamp).store")

        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: quarantineURL.path + suffix)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: source, to: destination)
        }

        AppLogger.fileIO.notice("Set the unreadable store aside at \(quarantineURL.lastPathComponent)")
        return quarantineURL
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
