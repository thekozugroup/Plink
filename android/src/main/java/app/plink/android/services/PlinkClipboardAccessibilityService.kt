package app.plink.android.services

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

class PlinkClipboardAccessibilityService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit
}
