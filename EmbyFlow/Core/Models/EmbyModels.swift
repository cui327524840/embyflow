import Foundation

struct PublicSystemInfo: Codable {
    var serverName: String?
    var version: String?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

struct UserDto: Codable {
    var id: String
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct AuthenticateResponse: Codable {
    var user: UserDto
    var accessToken: String
    var serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

struct UserItemData: Codable, Hashable {
    var playbackPositionTicks: Int64?
    var played: Bool?
    var playCount: Int?
    var isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
    }
}

struct ItemDto: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String?
    var collectionType: String?
    var mediaType: String?
    var overview: String?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var parentId: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]?
    var seriesId: String?
    var seriesName: String?
    var seriesPrimaryImageTag: String?
    var seasonId: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var runTimeTicks: Int64?
    var userData: UserItemData?
    var productionYear: Int?
    var communityRating: Double?
    var officialRating: String?
    var primaryImageAspectRatio: Double?
    var childCount: Int?
    var recursiveItemCount: Int?
    var isFolder: Bool?
    var genres: [String]?
    var taglines: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", collectionType = "CollectionType"
        case mediaType = "MediaType", overview = "Overview", imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags", parentId = "ParentId"
        case parentThumbItemId = "ParentThumbItemId", parentThumbImageTag = "ParentThumbImageTag"
        case parentBackdropItemId = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case seriesId = "SeriesId", seriesName = "SeriesName", seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case seasonId = "SeasonId", indexNumber = "IndexNumber", parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks", userData = "UserData", productionYear = "ProductionYear"
        case communityRating = "CommunityRating", officialRating = "OfficialRating"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio", childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount", isFolder = "IsFolder"
        case genres = "Genres", taglines = "Taglines"
    }
}

extension ItemDto {
    /// A container we browse into (library, folder, box set) rather than open as a title.
    var isFolderLike: Bool {
        switch type ?? "" {
        case "CollectionFolder", "Folder", "UserView", "AggregateFolder", "BoxSet", "PhotoAlbum", "Season", "Playlist":
            return true
        default:
            return false
        }
    }

    var isSeries: Bool { (type ?? "") == "Series" }

    var isPlayable: Bool {
        if mediaType == "Video" { return true }
        switch type ?? "" {
        case "Movie", "Episode", "Video", "MusicVideo", "Trailer":
            return true
        default:
            return false
        }
    }

    var duration: Double? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        return ticks.secondsFromTicks
    }

    var resumeSeconds: Double? {
        guard let ticks = userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks.secondsFromTicks
    }

    var watchedProgress: Double {
        guard let position = resumeSeconds, let total = duration, total > 0 else { return 0 }
        return min(1, max(0, position / total))
    }

    var isPlayed: Bool { userData?.played == true }

    var isFavorite: Bool { userData?.isFavorite == true }

    var episodeLabel: String? {
        guard let episode = indexNumber else { return nil }
        if let season = parentIndexNumber {
            return String(format: "S%02dE%02d", season, episode)
        }
        return String(format: "E%02d", episode)
    }

    var metaLine: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(year)) }
        if let runtime = formatRuntime(duration) { parts.append(runtime) }
        if let rating = communityRating { parts.append(String(format: "%.1f", rating)) }
        if let official = officialRating, !official.isEmpty { parts.append(official) }
        return parts.joined(separator: " · ")
    }

    var shortMetaLine: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(year)) }
        if let type = type, ["Movie", "Series"].contains(type) { parts.append(type == "Movie" ? "电影" : "剧集") }
        return parts.joined(separator: " · ")
    }
}

struct ItemsQueryResult: Codable {
    var items: [ItemDto]
    var totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    init(items: [ItemDto] = [], totalRecordCount: Int = 0) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }
}
