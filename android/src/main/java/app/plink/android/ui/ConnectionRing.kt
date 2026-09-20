/*
 * Copyright (c) 2025-2026 Nishant Mishra
 *
 * This file is adapted from Tomato - a minimalist pomodoro timer for Android.
 *
 * Tomato is free software: you can redistribute it and/or modify it under the terms of the GNU
 * General Public License as published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Tomato is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with Tomato.
 * If not, see <https://www.gnu.org/licenses/>.
 */

package app.plink.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.plink.android.services.SessionStatus

@Composable
fun ConnectionRing(status: SessionStatus, modifier: Modifier = Modifier) {
    val ready = status == SessionStatus.READY
    val progress by animateFloatAsState(
        targetValue = if (ready) 1f else 0.08f,
        animationSpec = spring(),
        label = "connection ring"
    )
    val primary = MaterialTheme.colorScheme.primary

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .widthIn(max = 350.dp)
            .fillMaxWidth(0.88f)
            .aspectRatio(1f)
            .semantics {
                contentDescription = when (status) {
                    SessionStatus.READY -> "Paired and ready"
                    SessionStatus.REPAIR_REQUIRED -> "Pairing needs repair"
                    SessionStatus.DISCONNECTED -> "No paired Mac"
                }
            }
    ) {
        CircularProgressIndicator(
            progress = { progress },
            modifier = Modifier.fillMaxWidth(0.9f).aspectRatio(1f),
            color = primary,
            trackColor = MaterialTheme.colorScheme.primaryContainer,
            strokeWidth = 16.dp,
            gapSize = 8.dp
        )
        AnimatedContent(targetState = status, label = "connection status") { currentStatus ->
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    Icons.Rounded.Devices,
                    contentDescription = null,
                    tint = primary,
                    modifier = Modifier.fillMaxWidth(0.18f).aspectRatio(1f)
                )
                Text(
                    text = when (currentStatus) {
                        SessionStatus.READY -> "Ready"
                        SessionStatus.REPAIR_REQUIRED -> "Pair again"
                        SessionStatus.DISCONNECTED -> "Pair"
                    },
                    style = MaterialTheme.typography.displayMedium.copy(fontSize = 58.sp),
                    textAlign = TextAlign.Center
                )
                Text(
                    text = when (currentStatus) {
                        SessionStatus.READY -> "Pixel + Mac"
                        SessionStatus.REPAIR_REQUIRED -> "Security update"
                        SessionStatus.DISCONNECTED -> "Select a nearby Mac"
                    },
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}
