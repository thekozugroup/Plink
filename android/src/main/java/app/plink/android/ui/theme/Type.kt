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

import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.unit.sp
import app.plink.android.R

private val BaseTypography = Typography()

@OptIn(ExperimentalTextApi::class)
@Composable
fun plinkTypography(): Typography {
    val regularFont = Font(
        R.font.google_sans_flex,
        FontWeight.Normal,
        variationSettings = FontVariation.Settings(FontVariation.weight(400))
    )
    val roundedFont = Font(
        R.font.google_sans_flex,
        FontWeight.SemiBold,
        variationSettings = FontVariation.Settings(
            FontVariation.weight(600),
            FontVariation.Setting("ROND", 100f)
        )
    )
    val regular = remember(regularFont) { FontFamily(regularFont) }
    val rounded = remember(roundedFont) { FontFamily(roundedFont) }

    return remember(regular, rounded) {
        Typography(
            displayLarge = BaseTypography.displayLarge.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            displayMedium = BaseTypography.displayMedium.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            displaySmall = BaseTypography.displaySmall.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            headlineLarge = BaseTypography.headlineLarge.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            headlineMedium = BaseTypography.headlineMedium.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            headlineSmall = BaseTypography.headlineSmall.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            titleLarge = BaseTypography.titleLarge.copy(fontFamily = regular, fontFeatureSettings = "ss02, dlig"),
            titleMedium = BaseTypography.titleMedium.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            titleSmall = BaseTypography.titleSmall.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            bodyLarge = BaseTypography.bodyLarge.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            bodyMedium = BaseTypography.bodyMedium.copy(fontFamily = regular, fontFeatureSettings = "ss02, dlig"),
            bodySmall = BaseTypography.bodySmall.copy(fontFamily = regular, fontFeatureSettings = "ss02, dlig"),
            labelLarge = BaseTypography.labelLarge.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            labelMedium = BaseTypography.labelMedium.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig"),
            labelSmall = BaseTypography.labelSmall.copy(fontFamily = rounded, fontFeatureSettings = "ss02, dlig")
        )
    }
}

@OptIn(ExperimentalTextApi::class)
@Composable
fun plinkTopBarTitleStyle(): TextStyle {
    val topBarTitleFont = Font(
        R.font.google_sans_flex,
        FontWeight.Black,
        variationSettings = FontVariation.Settings(
            FontVariation.weight(900),
            FontVariation.width(112.5f),
            FontVariation.Setting("ROND", 35f)
        )
    )
    val topBarTitle = remember(topBarTitleFont) { FontFamily(topBarTitleFont) }

    return remember(topBarTitle) {
        TextStyle(
            fontFamily = topBarTitle,
            fontSize = 32.sp,
            lineHeight = 32.sp
        )
    }
}
