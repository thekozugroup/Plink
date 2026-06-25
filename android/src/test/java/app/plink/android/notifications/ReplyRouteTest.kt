package app.plink.android.notifications

import org.junit.Assert.assertEquals
import org.junit.Test

class ReplyRouteTest {
    @Test
    fun replyCommandRequiresText() {
        val route = ReplyRoute("com.example.messages", "key", "thread", canReply = true)
        val command = ReplyCommand(route, "On it")

        assertEquals("On it", command.text)
    }

    @Test(expected = IllegalArgumentException::class)
    fun blankReplyFailsClosed() {
        ReplyCommand(ReplyRoute("pkg", "key", null, canReply = true), " ")
    }
}
