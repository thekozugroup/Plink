package app.plink.android.notifications

data class ReplyRoute(
    val packageName: String,
    val notificationKey: String,
    val conversationId: String?,
    val canReply: Boolean
) {
    fun requireReplyable(): ReplyRoute {
        require(canReply) { "Notification does not expose a reply action." }
        return this
    }
}

data class ReplyCommand(
    val route: ReplyRoute,
    val text: String
) {
    init {
        require(text.isNotBlank()) { "Reply text cannot be blank." }
    }
}
