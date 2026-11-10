import Foundation

// Labels and nullable values are reconstructed explicitly; tuple positions are not inferred.

struct MessagingPersistenceFrozenMessageDTO: Codable, Sendable {
    let id: String
    let content: String

    init(_ row: (id: String, content: String)) {
        id = row.id
        content = row.content
    }

    var value: (id: String, content: String) {
        (id: id, content: content)
    }
}

struct MessagingPersistenceTranslationDTO: Codable, Sendable {
    let status: String
    let providerBilledChars: Int
    let targetLanguage: String
    let translatedContent: String

    init(_ row: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String)) {
        status = row.status
        providerBilledChars = row.providerBilledChars
        targetLanguage = row.targetLanguage
        translatedContent = row.translatedContent
    }

    var value: (status: String, providerBilledChars: Int, targetLanguage: String, translatedContent: String) {
        (status: status, providerBilledChars: providerBilledChars, targetLanguage: targetLanguage, translatedContent: translatedContent)
    }
}

struct MessagingPersistenceReadAckDTO: Codable, Sendable {
    let scopeId: String
    let throughSeq: Int

    init(_ row: (scopeId: String, throughSeq: Int)) {
        scopeId = row.scopeId
        throughSeq = row.throughSeq
    }

    var value: (scopeId: String, throughSeq: Int) {
        (scopeId: scopeId, throughSeq: throughSeq)
    }
}

struct MessagingPersistenceUserThreadFollowDTO: Codable, Sendable {
    let serverId: String
    let userId: String
    let threadChannelId: String
    let parentMessageId: String

    init(_ row: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String)) {
        serverId = row.serverId
        userId = row.userId
        threadChannelId = row.threadChannelId
        parentMessageId = row.parentMessageId
    }

    var value: (serverId: String, userId: String, threadChannelId: String, parentMessageId: String) {
        (serverId: serverId, userId: userId, threadChannelId: threadChannelId, parentMessageId: parentMessageId)
    }
}

struct MessagingPersistenceFollowerRemovalDTO: Codable, Sendable {
    let serverId: String
    let threadChannelId: String
    let agentId: String

    init(_ row: (serverId: String, threadChannelId: String, agentId: String)) {
        serverId = row.serverId
        threadChannelId = row.threadChannelId
        agentId = row.agentId
    }

    var value: (serverId: String, threadChannelId: String, agentId: String) {
        (serverId: serverId, threadChannelId: threadChannelId, agentId: agentId)
    }
}

struct MessagingPersistenceAgentReadCursorDTO: Codable, Sendable {
    let seq: Int
    let version: Int

    init(_ row: (seq: Int, version: Int)) {
        seq = row.seq
        version = row.version
    }

    var value: (seq: Int, version: Int) {
        (seq: seq, version: version)
    }
}

struct MessagingPersistenceAgentActivityDTO: Codable, Sendable {
    let title: String
    let text: String
    let producerFactId: String?

    init(_ row: (title: String, text: String, producerFactId: String?)) {
        title = row.title
        text = row.text
        producerFactId = row.producerFactId
    }

    var value: (title: String, text: String, producerFactId: String?) {
        (title: title, text: text, producerFactId: producerFactId)
    }
}
