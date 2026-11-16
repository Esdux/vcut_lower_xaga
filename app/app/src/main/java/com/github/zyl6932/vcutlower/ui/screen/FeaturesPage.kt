package com.github.zyl6932.vcutlower.ui.screen

import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import com.github.zyl6932.vcutlower.app.BatteryActivity
import com.github.zyl6932.vcutlower.app.ChargeActivity
import com.github.zyl6932.vcutlower.root.Vcut
import com.github.zyl6932.vcutlower.ui.util.PageScaffold
import com.github.zyl6932.vcutlower.ui.util.firstCard
import com.github.zyl6932.vcutlower.ui.util.nextCard
import kotlinx.coroutines.launch
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.preference.ArrowPreference

/**
 * 功能标签页：一张卡一个功能，各自打开一个二级页面。
 * 结构照搬 HyperMusicCover 的 FeatureList：卡片里一行 ArrowPreference，点进去是 Activity——
 * 转场、返回手势和预测性返回动画都由系统提供。
 *
 * 「临时取消 30 秒关机」与「设置 → 生成诊断包」同一形态：一行 ArrowPreference，点一下当场执行，
 * 结果用 Toast 回执，不跳页面、不弹确认框——它本来就是"现在马上别关机"的应急按钮。
 */
@Composable
fun FeaturesPage(
    status: Vcut.Status,
    isBlurEnabled: Boolean,
    extraBottomPadding: Dp,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val enabled = status.root && status.installed
    val skipped = Vcut.shutdownSkipped(status)

    PageScaffold(
        title = "功能",
        isBlurEnabled = isBlurEnabled,
        extraBottomPadding = extraBottomPadding,
    ) {
        item(key = "features") {
            Column {
                Card(modifier = Modifier.firstCard()) {
                    ArrowPreference(
                        title = "电池解容",
                        summary = "降低关机电压、均匀电量显示、循环与满充电压",
                        onClick = { context.startActivity(Intent(context, BatteryActivity::class.java)) },
                    )
                }
                Card(modifier = Modifier.nextCard()) {
                    ArrowPreference(
                        title = "充电增强",
                        summary = "亮屏快充、提升充电电流，带温度与电量护栏",
                        onClick = { context.startActivity(Intent(context, ChargeActivity::class.java)) },
                    )
                }

                SmallTitle(text = "应急")
                Card(modifier = Modifier.nextCard()) {
                    ArrowPreference(
                        title = "临时取消 30 秒关机",
                        summary = if (skipped) "本轮已取消，电压回到闸以上或插上充电器后恢复"
                        else "撤掉本次倒计时，只影响这一轮，其余交回系统判定",
                        enabled = enabled && !skipped,
                        onClick = {
                            scope.launch {
                                val ok = Vcut.cancelShutdownNow()
                                Toast.makeText(
                                    context,
                                    if (ok) "已取消本轮关机倒计时" else "取消失败：写内核参数被拒绝",
                                    Toast.LENGTH_SHORT,
                                ).show()
                            }
                        },
                    )
                }
            }
        }
    }
}
