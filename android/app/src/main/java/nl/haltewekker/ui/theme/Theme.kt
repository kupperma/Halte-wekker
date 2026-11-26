package nl.haltewekker.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import nl.haltewekker.data.VehicleKind

/** The iOS new look's tokens (`Design.swift`, `DesignShared.swift`), light and dark. */
@Immutable
data class Tokens(
    val text: Color, val secondary: Color, val surface: Color, val surface2: Color, val surface3: Color, val divider: Color,
    val accent: Color, val accentText: Color, val accentSoft: Color, val accentSoftText: Color, val warning: Color,
    val page: Color, val legQuiet: Color, val tram: Color,
) {
    companion object {
        val bus = Color(0xFFE0632E)
        val intercity = Color(0xFF3B44B0)
        val sprinter = Color(0xFF0A93B5)
        val onAccent = Color.White

        val light = Tokens(
            text = Color(0xFF14171A), secondary = Color(0xFF5B636B), surface = Color(0xFFFFFFFF), surface2 = Color(0xFFF6F7F9),
            surface3 = Color(0xFFF1F3F5), divider = Color(0xFFECEEF0), accent = Color(0xFF0E7A55), accentText = Color(0xFF0E7A55),
            accentSoft = Color(0xFFE3F3EC), accentSoftText = Color(0xFF0A5C40), warning = Color(0xFFA84219), page = Color(0xFFF1F3F5),
            legQuiet = Color(0xFF8A929A), tram = Color(0xFF6B3FA0),
        )
        val dark = Tokens(
            text = Color(0xFFECEEF0), secondary = Color(0xFFA3ABB3), surface = Color(0xFF1C1F23), surface2 = Color(0xFF24282D),
            surface3 = Color(0xFF2C3137), divider = Color(0xFF33383E), accent = Color(0xFF0E7A55), accentText = Color(0xFF4CC792),
            accentSoft = Color(0xFF163A2C), accentSoftText = Color(0xFF8FE0BB), warning = Color(0xFFFF8A5C), page = Color(0xFF111417),
            legQuiet = Color(0xFF6B747E), tram = Color(0xFF7A55B0),
        )
    }

    /** The pill colour for a kind of vehicle (set C1: the bus orange, the intercity indigo, the sprinter cyan). */
    fun kind(k: VehicleKind): Color = when (k) {
        VehicleKind.BUS -> bus
        VehicleKind.SPRINTER -> sprinter
        VehicleKind.TRAM, VehicleKind.METRO -> tram
        else -> intercity
    }
}

val LocalTokens = staticCompositionLocalOf { Tokens.light }

object DS {
    val cardRadius = 24.dp
    val chipRadius = 20.dp
    val fieldRadius = 16.dp
    val pillRadius = 6.dp
    val edge = 12.dp
    val hit = 44.dp
    val cta = 56.dp
    val t: Tokens @Composable get() = LocalTokens.current
}

@Composable
fun HaltewekkerTheme(content: @Composable () -> Unit) {
    val darkMode = isSystemInDarkTheme()
    val t = if (darkMode) Tokens.dark else Tokens.light
    val scheme = if (darkMode) darkColorScheme(
        primary = t.accentText, onPrimary = Color(0xFF00281A), primaryContainer = t.accentSoft, onPrimaryContainer = t.accentSoftText,
        secondary = t.secondary, background = t.page, onBackground = t.text, surface = t.surface, onSurface = t.text,
        surfaceVariant = t.surface2, onSurfaceVariant = t.secondary, surfaceContainer = t.surface2, surfaceContainerHigh = t.surface3,
        outline = t.divider, outlineVariant = t.divider, error = t.warning,
    ) else lightColorScheme(
        primary = t.accent, onPrimary = Color.White, primaryContainer = t.accentSoft, onPrimaryContainer = t.accentSoftText,
        secondary = t.secondary, background = t.page, onBackground = t.text, surface = t.surface, onSurface = t.text,
        surfaceVariant = t.surface2, onSurfaceVariant = t.secondary, surfaceContainer = t.surface2, surfaceContainerHigh = t.surface3,
        outline = t.divider, outlineVariant = t.divider, error = t.warning,
    )
    val shapes = Shapes(
        small = RoundedCornerShape(DS.fieldRadius), medium = RoundedCornerShape(DS.chipRadius), large = RoundedCornerShape(DS.cardRadius),
    )
    CompositionLocalProvider(LocalTokens provides t) {
        MaterialTheme(colorScheme = scheme, shapes = shapes, content = content)
    }
}
