package com.github.zyl6932.vcutlower.root

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.UUID

/**
 * 常驻的 su 会话。
 *
 * 首页每 3 秒刷新一次状态，每次都 fork 一个 su 太浪费；这里只开一个 su 进程，命令按顺序写进
 * 它的 stdin，每条命令后面跟一个随机标记行，读到标记就算这条命令结束（标记里带退出码）。
 * stderr 并进 stdout（2>&1），所以输出就是用户在终端里会看到的样子。
 *
 * KernelSU 默认不弹授权框：没在管理器「超级用户」里放行时，su 会直接退出，
 * 表现为 [run] 返回 null —— 界面据此提示去管理器授权。
 */
object RootShell {

    class Result(val code: Int, val out: String) {
        val ok get() = code == 0
        val lines get() = out.lines().filter { it.isNotEmpty() }
    }

    private val lock = Mutex()
    private var process: Process? = null
    private var stdin: OutputStreamWriter? = null
    private var stdout: BufferedReader? = null

    /** 最近一次是否拿到了 root；null = 还没试过 */
    @Volatile
    var granted: Boolean? = null
        private set

    private fun open(): Boolean {
        process?.let { if (it.isAlive) return true }
        // 常见 su 位置：先按 PATH 找，再按绝对路径兜底（某些 ROM 的 app PATH 不含 /system/bin）
        for (cmd in listOf("su", "/system/bin/su", "/data/adb/ksu/bin/su")) {
            var p: Process? = null
            try {
                p = ProcessBuilder(cmd).redirectErrorStream(true).start()
                val rdr = BufferedReader(InputStreamReader(p.inputStream, Charsets.UTF_8))
                // su 若被 KSU 拒绝，会在启动后极短时间内退出并打印原因；先探一下
                Thread.sleep(300)
                if (!p.isAlive) {
                    val txt = try { rdr.readText() } catch (_: Throwable) { "" }
                    android.util.Log.w("VcutRoot", "su exited immediately via " + cmd + ": "
                            + txt.take(300).replace('\n', ' '))
                    continue
                }
                process = p
                stdin = OutputStreamWriter(p.outputStream, Charsets.UTF_8)
                stdout = rdr
                android.util.Log.i("VcutRoot", "su opened via: " + cmd)
                return true
            } catch (e: Exception) {
                android.util.Log.w("VcutRoot", "su open failed via " + cmd + ": " + e.javaClass.name + " " + e.message)
                runCatching { p?.destroy() }
            }
        }
        close()
        return false
    }

    private fun close() {
        runCatching { process?.destroy() }
        process = null
        stdin = null
        stdout = null
    }

    /**
     *
     * 每次 fork 一个 `su -c`，不再维持常驻 su 会话。
     * 常驻会话要往 su 的 stdin 写命令再读 marker，
     * 在当前 KernelSU 上写完就卡住（su 进程活着却不回显）
     * `su -c` 一次一命令与 runDetached 同路径，实测可用。
     */
    suspend fun run(script: String): Result? = withContext(Dispatchers.IO) {
        lock.withLock {
            var p: Process? = null
            try {
                p = ProcessBuilder("su", "-c", "( $script\n) 2>&1")
                    .redirectErrorStream(true)
                    .start()
                val out = p.inputStream.bufferedReader().readText()
                val code = p.waitFor()
                granted = true
                Result(code, out.trimEnd())
            } catch (e: Exception) {
                android.util.Log.w("VcutRoot", "su -c failed: " + e.javaClass.name + " " + e.message)
                runCatching { p?.destroy() }
                granted = false
                null
            }
        }
    }

    /**
     * 单独开一个 su 进程跑耗时命令（生成诊断包要 1~2 分钟），不占常驻会话，
     * 首页的定时刷新照常进行。onLine 逐行回调输出，用于显示进度。
     */
    suspend fun runDetached(script: String, onLine: (String) -> Unit = {}): Result? =
        withContext(Dispatchers.IO) {
            try {
                val p = ProcessBuilder("su", "-c", script).redirectErrorStream(true).start()
                val sb = StringBuilder()
                p.inputStream.bufferedReader().forEachLine {
                    sb.append(it).append('\n')
                    onLine(it)
                }
                Result(p.waitFor(), sb.toString().trimEnd())
            } catch (_: Exception) {
                null
            }
        }

    /** 把任意文本安全地写进文件（经 base64，避免引号/换行转义问题）。 */
    suspend fun writeFile(path: String, content: String): Boolean {
        val b64 = android.util.Base64.encodeToString(content.toByteArray(), android.util.Base64.NO_WRAP)
        return run("echo '$b64' | base64 -d > '$path'")?.ok == true
    }
}
