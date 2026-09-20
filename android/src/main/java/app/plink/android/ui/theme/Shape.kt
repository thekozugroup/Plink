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

package app.plink.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp

val PlinkShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(16.dp),
    medium = RoundedCornerShape(24.dp),
    large = RoundedCornerShape(32.dp),
    extraLarge = RoundedCornerShape(40.dp)
)

object PlinkShapeDefaults {
    val paneMaxWidth = 600.dp

    @Composable
    fun groupedItem(index: Int, count: Int): RoundedCornerShape = when {
        count == 1 -> RoundedCornerShape(32.dp)
        index == 0 -> RoundedCornerShape(
            topStart = 32.dp,
            topEnd = 32.dp,
            bottomStart = 8.dp,
            bottomEnd = 8.dp
        )
        index == count - 1 -> RoundedCornerShape(
            topStart = 8.dp,
            topEnd = 8.dp,
            bottomStart = 32.dp,
            bottomEnd = 32.dp
        )
        else -> RoundedCornerShape(8.dp)
    }
}
