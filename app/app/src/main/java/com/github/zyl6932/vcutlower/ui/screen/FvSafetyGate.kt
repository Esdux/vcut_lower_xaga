package com.github.zyl6932.vcutlower.ui.screen

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.edit
import kotlinx.coroutines.delay
import androidx.compose.ui.text.style.TextAlign
import top.yukonga.miuix.kmp.basic.Button
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Text as MiuixText
import top.yukonga.miuix.kmp.theme.LocalDismissState
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.window.WindowDialog

/**
 * 「抬高充电电压上限」的安全确认闸（2026-11-06）。
 *
 * 这个开关会真的把满充上限往上抬（4445 → 4450~4580 mV），风险由使用者承担，
 * 所以打开前必须走两级确认：
 *   ① 年龄与知情确认：已满 18 周岁 + 知晓风险自担；
 *   ② 强制安全警告：完整风险文本，**必须停留 30 秒**才能点「确认开启」，提前关掉不算确认。
 * 只有两级都通过，开关才真正生效；任何一步取消都不写内核参数，开关保持关闭。
 *
 * 确认结果记在 SharedPreferences 里，**只记一次**：确认过以后，同一台设备上再打开
 * 这个开关不再弹窗，直接生效（用户要求「确认一次后无需确认」）。
 * 需要重新阅读时调 [resetConfirmed] 清掉标记即可（暂未做 UI 入口）。
 */
object FvSafetyGate {

    private const val PREFS_NAME = "fv_safety"
    private const val KEY_CONFIRMED = "confirmed_v1"

    /** 强制阅读倒计时：30 秒（用户要求「等待 30 秒后才可确认」）。 */
    const val WARNING_SECONDS = 30

    /** 是否已经确认过（一次即永久，除非手动清掉）。 */
    fun isConfirmed(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_CONFIRMED, false)

    /** 记录已确认。只写一次，之后所有开关都放行。 */
    fun confirm(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit {
            putBoolean(KEY_CONFIRMED, true)
        }
    }

    /** 清掉确认状态（供以后可能的「重新阅读安全须知」入口使用）。 */
    fun resetConfirmed(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit {
            remove(KEY_CONFIRMED)
        }
    }

    /** 警告正文：按用户给的参考文本排的版，标题一句 + 三段正文 + 结尾一句。 */
    private val PARAGRAPHS = listOf(
        "电池过充具有严重安全隐患！",
        "过充可能导致电芯内部发生不可逆化学反应，引发电解液分解、产气、鼓包、内部短路及" +
            "温度急剧升高。严重时可能发生热失控，造成电池起火、爆炸，甚至引发人身伤害和财产损失。",
        "禁止在不了解电芯安全参数的情况下提高充电电压、解除过压保护或强制持续充电。" +
            "电池即使暂时没有异常，也不代表没有受到损伤。",
        "电池保护板并非绝对可靠。保护阈值、检测可能存在误差，MOS 管或保护电路也可能失效。" +
            "绕过或提高保护阈值后，更不能依赖保护板兜底。",
        "请勿轻易尝试！操作风险由使用者自行承担。",
    )

    /**
     * 单行按钮：miuix 的 [TextButton] 内部 Text 没设 maxLines，文案一长就折成两行，
     * 把对话框按钮区撑高。这里直接用 [Button] + 自己的 [MiuixText]，锁死单行。
     */
    @Composable
    private fun SingleLineButton(
        text: String,
        onClick: () -> Unit,
        modifier: Modifier = Modifier,
        enabled: Boolean = true,
        primary: Boolean = false,
    ) {
        Button(
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            colors = if (primary) ButtonDefaults.buttonColorsPrimary()
            else ButtonDefaults.buttonColors(),
        ) {
            MiuixText(
                text = text,
                style = MiuixTheme.textStyles.button,
                maxLines = 1,
                softWrap = false,
                textAlign = TextAlign.Center,
            )
        }
    }

    /**
     * 两级确认流程的宿主，放在页面里，配合页面自己的 stage 状态使用。
     *
     * @param stage null = 不显示；1 = 年龄/知情确认；2 = 强制安全警告（30 秒倒计时）
     * @param onStageChange 切换或关闭当前级
     * @param onConfirm 两级都通过后调用——此时才真正去写内核参数
     */
    @Composable
    fun Dialogs(
        stage: Int?,
        onStageChange: (Int?) -> Unit,
        onConfirm: () -> Unit,
    ) {
        val context = LocalContext.current

        // ---- 第一级：年龄与知情确认 ----
        WindowDialog(
            show = stage == 1,
            title = "开启前请先确认",
            summary = "这个开关会真的抬高电池的满充电压上限，属于超出原厂设计的操作。",
            onDismissRequest = { onStageChange(null) },
        ) {
            val dismiss = LocalDismissState.current
            Column(Modifier.fillMaxWidth()) {
                MiuixText(
                    text = "请确认以下三点：\n\n" +
                        "1. 我已年满 18 周岁，具备完全民事行为能力；\n" +
                        "2. 我知晓这会提高电池过充风险，可能造成电池鼓包、起火甚至人身伤害；\n" +
                        "3. 由此产生的一切后果由我自行承担。",
                    style = MiuixTheme.textStyles.body2,
                )
                Spacer(Modifier.height(16.dp))
                Row {
                    SingleLineButton(
                        modifier = Modifier.weight(1f),
                        text = "取消",
                        onClick = { dismiss?.invoke() },
                    )
                    Spacer(Modifier.width(20.dp))
                    SingleLineButton(
                        modifier = Modifier.weight(1f),
                        text = "已满 18 周岁",
                        onClick = { onStageChange(2) },
                        primary = true,
                    )
                }
            }
        }

        // ---- 第二级：强制安全警告，30 秒倒计时 ----
        var remaining by remember { mutableIntStateOf(WARNING_SECONDS) }
        // 每次进入这一级都重新计时；中途关掉再打开也从 30 秒重来，避免攒时间跳过阅读
        LaunchedEffect(stage) {
            if (stage == 2) {
                remaining = WARNING_SECONDS
                while (remaining > 0) {
                    delay(1_000)
                    remaining -= 1
                }
            }
        }

        WindowDialog(
            show = stage == 2,
            title = "安全警告",
            summary = "请完整阅读以下内容。$WARNING_SECONDS 秒内无法确认。",
            onDismissRequest = { onStageChange(null) },
        ) {
            val dismiss = LocalDismissState.current
            Column(Modifier.fillMaxWidth()) {
                // 正文较长，限高 + 可滚动，避免把按钮挤出屏幕
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 340.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    PARAGRAPHS.forEachIndexed { i, para ->
                        MiuixText(
                            text = para,
                            style = MiuixTheme.textStyles.body2,
                            fontWeight = if (i == 0 || i == PARAGRAPHS.lastIndex) FontWeight.Bold
                            else FontWeight.Normal,
                        )
                        if (i != PARAGRAPHS.lastIndex) Spacer(Modifier.height(10.dp))
                    }
                }

                Spacer(Modifier.height(16.dp))
                Row {
                    SingleLineButton(
                        modifier = Modifier.weight(1f),
                        text = "取消",
                        onClick = { dismiss?.invoke() },
                    )
                    Spacer(Modifier.width(20.dp))
                    SingleLineButton(
                        modifier = Modifier.weight(1f),
                        text = if (remaining > 0) "请阅读 (${remaining}s)" else "确认开启",
                        onClick = {
                            // 保险：即使按钮状态异常也不放行未满 30 秒的确认
                            if (remaining <= 0) {
                                confirm(context)
                                dismiss?.invoke()
                                onConfirm()
                            }
                        },
                        enabled = remaining <= 0,
                        primary = true,
                    )
                }
            }
        }
    }
}
