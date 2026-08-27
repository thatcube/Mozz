import Foundation

/// The durable desired favorite/rating state for one provider item.
public struct FavoriteMutationState: Codable, Sendable, Equatable {
    public var remoteID: String
    public var itemType: String
    public var kind: String
    public var value: Double?
    public var updatedAtMS: Int64
    public var sourceDeviceID: String
    public var needsServerWrite: Bool

    public init(
        remoteID: String,
        itemType: String,
        kind: String,
        value: Double?,
        updatedAtMS: Int64,
        sourceDeviceID: String,
        needsServerWrite: Bool
    ) {
        self.remoteID = remoteID
        self.itemType = itemType
        self.kind = kind
        self.value = value
        self.updatedAtMS = updatedAtMS
        self.sourceDeviceID = sourceDeviceID
        self.needsServerWrite = needsServerWrite
    }
}
