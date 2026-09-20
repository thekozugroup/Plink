package app.plink.android.debug

import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager

/** Synthetic visual input for the normal consented capture path. Debug builds only. */
class ScreenPreviewPatternActivity : Activity() {
    private lateinit var pattern: Pattern

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (intent.getBooleanExtra(EXTRA_PROTECTED, false)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        pattern = Pattern(this)
        setContentView(pattern)
    }

    override fun onResume() {
        super.onResume()
        pattern.start()
    }

    override fun onPause() {
        pattern.stop()
        super.onPause()
    }

    override fun onDestroy() {
        pattern.stop()
        super.onDestroy()
    }

    private class Pattern(context: Context) : View(context) {
        private val handler = Handler(Looper.getMainLooper())
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var tick = 0
        private var running = false
        private val next = object : Runnable {
            override fun run() {
                if (!running) return
                tick++
                invalidate()
                handler.postDelayed(this, 500)
            }
        }

        init { contentDescription = "Plink synthetic moving screen pattern" }

        fun start() {
            if (running) return
            running = true
            handler.post(next)
        }

        fun stop() {
            running = false
            handler.removeCallbacks(next)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            canvas.drawColor(Color.rgb(16, 24, 48))
            val stripe = width / 4f
            val colors = intArrayOf(Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW)
            for (index in colors.indices) {
                paint.color = colors[index]
                canvas.drawRect(index * stripe, height * .2f, (index + 1) * stripe, height * .45f, paint)
            }
            paint.color = if (tick % 2 == 0) Color.MAGENTA else Color.CYAN
            val radius = minOf(width, height) * .08f
            val x = radius + (width - 2 * radius) * (tick % 8) / 7f
            canvas.drawCircle(x, height * .62f, radius, paint)
            paint.color = Color.WHITE
            paint.textSize = width * .06f
            canvas.drawText("Plink capture check", width * .06f, height * .12f, paint)
            canvas.drawText("Frame $tick", width * .06f, height * .83f, paint)
        }
    }

    companion object {
        const val EXTRA_PROTECTED = "plink_test_protected_content"
    }
}
