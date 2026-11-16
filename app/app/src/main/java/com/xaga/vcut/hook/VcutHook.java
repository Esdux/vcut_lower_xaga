package com.xaga.vcut.hook;

import android.app.Application;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;
import android.util.Log;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

import io.github.libxposed.api.XposedInterface;
import io.github.libxposed.api.XposedModule;
import io.github.libxposed.api.XposedModuleInterface.HotReloadedParam;
import io.github.libxposed.api.XposedModuleInterface.HotReloadingParam;
import io.github.libxposed.api.XposedModuleInterface.ModuleLoadedParam;
import io.github.libxposed.api.XposedModuleInterface.PackageLoadedParam;
import io.github.libxposed.api.XposedModuleInterface.PackageReadyParam;
import io.github.libxposed.api.XposedModuleInterface.SystemServerStartingParam;

/**
 * VCut Lower / PowerSave guard -- LSPosed libxposed API 102.
 *
 * MIUI PowerSaveService (com.miui.securitycenter) shuts the phone down with a
 * 30s countdown in ph.v.g0(Intent).  The real condition is a FALLING EDGE:
 *
 *   (A == 2 || (G == 2 && A <= 2)) && status == 3 && level == 1
 *   && yh.c0.q(ctx) == 0 && mExtremeModeUiOpen
 *
 * A is the level seen by the previous g0() call; ph.v.f0() only calls g0()
 * when level/status changes.  BATTERY_CHANGED is sticky, so re-enabling the
 * service replays a cached intent.  The service has NO voltage threshold at
 * all -- "3.4V triggers shutdown" is just the gauge reporting SOC 0/1 there.
 *
 * WHY THIS VERSION EXISTS (2026-11-05):
 * the old hook read /sys/module/vcut_lower/parameters/{enable,t_vpack,
 * vcut_delay} on every broadcast.  com.miui.securitycenter runs as
 * u:r:system_app:s0 and SELinux denies reads of sysfs:
 *   avc: denied { read } name="vcut_delay" ... permissive=0
 * readInt(MP+"enable", 0) therefore returned 0, "enable == 1" was never
 * true, and the guard NEVER ran.  It also treated "cannot read config" as
 * "protection disabled" instead of failing safe.
 *
 * New design -- zero sysfs / zero /data/adb reads:
 *   - Voltage comes straight from BATTERY_CHANGED's "voltage" extra (mV),
 *     which system_app is already allowed to read.
 *   - The shutdown floor comes from Settings.Global (root writes it via
 *     "settings put global", system_app reads it through ContentResolver).
 *     VCut's shutdown-voltage slider and service.sh both publish it, so the
 *     next broadcast already uses the new value -- no reboot, no hot reload.
 *   - Fail-safe defaults: no resolver / no key / malformed value still means
 *     "guard ON, floor 3000mV".  Losing config can never disable protection.
 *   - While vbat > floor, g0() sees level=2 (no shutdown, A becomes 2).
 *     At vbat <= floor and discharging, g0() sees level=1: the 2->1 falling
 *     edge starts the 30s countdown exactly at the user's shutdown voltage.
 *     We FORCE 1 instead of trusting the gauge, because the gauge flickers
 *     0/1 near empty and a plain "pass through" often missed the edge.
 *   - vcut_pc_guard=0 forces level=2 forever (framework never shuts down).
 *   - Charging (status==2) always gets level=2; g0() cancels any countdown.
 *
 * The intent is copied rather than mutated in place because ph.v.f0() passes
 * the same Intent to several other listeners, which must keep seeing the real
 * battery level.
 */
public final class VcutHook extends XposedModule {

    private static final String TAG = "VcutHook";
    private static final String SCOPE_PKG = "com.miui.securitycenter";
    private static final String SCOPE_SYSTEM = "android";
    private static final String HOOK_ID = "powersave_g0";

    /** Published by VCut's shutdown-voltage slider and by service.sh. */
    private static final String KEY_FLOOR = "vcut_delay_mv";
    private static final String KEY_ENABLE = "vcut_guard_enabled";
    private static final String KEY_PC_GUARD = "vcut_pc_guard";

    /**
     * 用户在"功能"页按了"临时取消本次关机倒计时"时由 App 写下的闩锁，
     * 内容是该次取消的到期时刻（epoch 秒），不是布尔值。
     *
     * 为什么不是布尔值：本轮结束后没有任何进程会把布尔闩锁改回 0（内核在回到
     * 闸以上或插充电器时清自己的 shut_skip，但 system_app 读不到 sysfs），一个
     * 布尔闩锁会把之后每一轮的倒计时永久吞掉。时间戳到期后这里自动恢复放行。
     */
    private static final String KEY_SHUT_SKIP = "vcut_shut_skip";

    /**
     * RULE 1: obfuscated class names change between securitycenter builds;
     * keep every known spelling and try them in order.  A new build means one
     * more row here, never a new branch in the matching logic.
     */
    private static final String[] POWERSAVE_CANDIDATES = {
            "ph.v",   // securitycenter 13.6.5 and earlier
            "nh.v",   // securitycenter 13.6.6 (ph.* -> nh.*)
    };

    private static final int DEFAULT_FLOOR = 3000;
    private static final int ARM_LEVEL = 2;
    private static final int RELEASE_LEVEL = 1;

    private volatile boolean hooked = false;
    /** Retry bookkeeping: installing too early gets ClassNotFoundException. */
    private volatile int attempts = 0;
    private static final int MAX_ATTEMPTS = 40;

    /** Framework requires a public no-arg constructor. */
    public VcutHook() {
    }

    /** Some LSPosed builds report the process name (":power", ":remote")
     *  instead of the bare package name here; match by prefix. */
    private static boolean inScope(String pkg) {
        return pkg != null && (pkg.startsWith(SCOPE_PKG) || SCOPE_SYSTEM.equals(pkg));
    }

    /** Unconditional diagnostic: proves the module APK was loaded at all. */
    @Override
    public void onModuleLoaded(ModuleLoadedParam param) {
        log(Log.INFO, TAG, "module loaded process=" + param.getProcessName()
                + " systemServer=" + param.isSystemServer()
                + " floor=" + globalInt(resolver(null), KEY_FLOOR, DEFAULT_FLOOR));
    }

    @Override
    public void onPackageLoaded(PackageLoadedParam param) {
        if (!inScope(param.getPackageName())) {
            return;
        }
        scheduleInstall(param.getDefaultClassLoader(), "PackageLoaded");
    }

    @Override
    public void onPackageReady(PackageReadyParam param) {
        if (!inScope(param.getPackageName())) {
            return;
        }
        scheduleInstall(param.getClassLoader(), "PackageReady");
    }

    /**
     * system_server loads through THIS callback, not onPackageLoaded.  Without
     * it the module is listed as scoped to android but install() never runs,
     * which is exactly the symptom: LSPosed DB has ('vcutlower','android',0)
     * yet not a single systemServer=true log line.
     */
    @Override
    public void onSystemServerStarting(SystemServerStartingParam param) {
        log(Log.INFO, TAG, "onSystemServerStarting");
        scheduleInstall(param.getClassLoader(), "SystemServerStarting");
    }

    /**
     * ph.v lives in classes3.dex.  onPackageLoaded can fire before that dex is
     * on the app classloader's path -- the :cache process resolves it, the main
     * process throws ClassNotFoundException at that same moment and, in the old
     * code, never tried again.  Retry on a short timer instead of a single
     * attempt, and stop as soon as one succeeds.
     */
    private void scheduleInstall(final ClassLoader cl, final String why) {
        if (hooked || cl == null) {
            return;
        }
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                for (int i = 0; i < MAX_ATTEMPTS && !hooked; i++) {
                    if (attempts++ == 0) {
                        log(Log.INFO, TAG, "install start (" + why + ")");
                    }
                    if (installOnce(cl)) {
                        log(Log.INFO, TAG, "g0 hooked after " + (i + 1)
                                + " attempt(s) via " + why);
                        return;
                    }
                    try {
                        Thread.sleep(i < 10 ? 200 : 500);
                    } catch (InterruptedException ie) {
                        return;
                    }
                }
                if (!hooked) {
                    log(Log.WARN, TAG, "gave up after " + MAX_ATTEMPTS
                            + " attempts (" + why + ")");
                }
            }
        }, "vcut-install");
        t.setDaemon(true);
        t.start();
    }

    private boolean installOnce(ClassLoader cl) {
        synchronized (this) {
            if (hooked) {
                return true;
            }
            try {
                // system_server: hook MiuiBatteryServiceImpl for the normal
                // low-battery shutdown path (not the extreme-mode path).
                // Use the classloader from onSystemServerStarting, NOT
                // ClassLoader.getSystemClassLoader(): system_server's classes
                // live on its own classloader, and the system one misses them.
                // RULE 4: forName's second argument stays false.  true would
                // force <clinit> of a class whose static init reads sysfs and
                // Settings before the process context exists -- that throws
                // ExceptionInInitializerError, and forty retries of it turn
                // into a crash loop for whoever owns the process.
                Class<?> bs = Class.forName("com.android.server.MiuiBatteryServiceImpl", false, cl);
                // Hook BatteryHandler's handleMessage: this is where the
                // SHUTDOWN_DELAY broadcast is sent (case 7).  The kernel sends
                // uevent -> BatteryUEventObserver -> BatteryHandler.handleMessage
                // -> sendStickyBroadcast.  We intercept handleMessage to apply
                // our threshold and inject our own broadcast when needed.
                Class<?> bh = null;
                for (Class<?> c : bs.getDeclaredClasses()) {
                    log(Log.INFO, TAG, "system_server inner class: " + c.getName());
                    if ("BatteryHandler".equals(c.getSimpleName())) {
                        bh = c;
                        break;
                    }
                }
                if (bh != null) {
                    for (Method m : bh.getDeclaredMethods()) {
                        if ("handleMessage".equals(m.getName())) {
                            m.setAccessible(true);
                            hook(m).setId(HOOK_ID + "_sys").intercept(new SystemShutdownHooker());
                            log(Log.INFO, TAG, "system_server BatteryHandler.handleMessage hooked");
                        }
                    }
                } else {
                    log(Log.WARN, TAG, "system_server BatteryHandler not found");
                }
                hooked = true;
                log(Log.INFO, TAG, "system_server MiuiBatteryServiceImpl hooked");
                return true;
            } catch (Throwable t) {
                // Fallback: securitycenter's PowerSaveService for extreme mode.
                // RULE 1: PowerOffUI/PowerSaveService live behind an obfuscated
                // package name that changes between securitycenter builds (ph ->
                // nh across 13.6.5 -> 13.6.6).  Walk a candidate list, never a
                // single hardcoded name; a new build only adds a row here.
                for (String name : POWERSAVE_CANDIDATES) {
                    try {
                        Class<?> cls = Class.forName(name, false, cl);
                        Method f0 = findByName(cls, "f0", Intent.class);
                        Method g0 = findByName(cls, "g0", Intent.class);
                        if (g0 == null) {
                            continue;
                        }
                        if (f0 != null) {
                            hook(f0).setId(HOOK_ID + "_f0").intercept(new G0Hooker());
                        }
                        hook(g0).setId(HOOK_ID).intercept(new G0Hooker());
                        hooked = true;
                        log(Log.INFO, TAG, "f0+g0 hooked on " + name
                                + " (libxposed api=" + getApiVersion()
                                + ", source=Settings.Global)");
                        return true;
                    } catch (Throwable ignored) {
                    }
                }
                log(Log.DEBUG, TAG, "attempt " + attempts + " miss: " + t);
                return false;
            }
        }
    }

    /**
     * ContentResolver of the hooked process.  ph.v keeps a Context in one of
     * its fields; find it by TYPE so we don't depend on the obfuscated name.
     * Fallback to ActivityThread.currentApplication().  Never throws.
     */
    private static android.content.Context getSystemContext() {
        /*
         * RULE 5: never reflect ActivityThread.systemMain().  It runs
         * new ActivityThread() + attach(true, 0), which installs a FAKE
         * instance into sCurrentActivityThread and poisons every other
         * component in the process (androidx.work ForceStopRunnable then
         * reads a null process name and crashes).
         *
         * currentActivityThread() is the real one and is already non-null in
         * system_server by the time this hook runs.  Its system context lives
         * in mSystemContext; read it by TYPE so no field name is assumed, and
         * fall back to any other Context field on the activity thread.
         */
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object thread = at.getMethod("currentActivityThread").invoke(null);
            if (thread == null) {
                return null;
            }
            for (Field f : at.getDeclaredFields()) {
                if (Context.class.isAssignableFrom(f.getType())
                        && !Application.class.isAssignableFrom(f.getType())) {
                    f.setAccessible(true);
                    Context c = (Context) f.get(thread);
                    if (c != null) {
                        return c;
                    }
                }
            }
            return null;
        } catch (Throwable t) {
            return null;
        }
    }

    /** RULE 3: look a method up by exact signature, null when absent. */
    private static Method findByName(Class<?> cls, String name, Class<?>... params) {
        try {
            Method m = cls.getDeclaredMethod(name, params);
            m.setAccessible(true);
            return m;
        } catch (Throwable ignored) {
            return null;
        }
    }

    /**
     * RULE 2: the outer instance of an inner class sits in a field whose NAME
     * changes with every build (this$0 today, something else tomorrow).  Find
     * it by TYPE: the synthetic enclosing-reference field whose value is not
     * the inner instance itself.
     */
    private static Object outerOf(Object inner) {
        if (inner == null) {
            return null;
        }
        Class<?> cls = inner.getClass();
        for (Field f : cls.getDeclaredFields()) {
            if (!f.isSynthetic()) {
                continue;
            }
            try {
                f.setAccessible(true);
                Object v = f.get(inner);
                if (v != null && v != inner && !cls.isInstance(v)) {
                    return v;
                }
            } catch (Throwable ignored) {
            }
        }
        return null;
    }

    /** First non-static field of the given type on obj, or null. */
    private static Object fieldOfType(Object obj, Class<?> type) {
        if (obj == null) {
            return null;
        }
        for (Class<?> c = obj.getClass(); c != null && c != Object.class; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (!type.isAssignableFrom(f.getType())) {
                    continue;
                }
                try {
                    f.setAccessible(true);
                    Object v = f.get(obj);
                    if (v != null) {
                        return v;
                    }
                } catch (Throwable ignored) {
                }
            }
        }
        return null;
    }

    private static ContentResolver resolver(Object self) {
        if (self != null) {
            try {
                for (Field f : self.getClass().getDeclaredFields()) {
                    if (Context.class.isAssignableFrom(f.getType())) {
                        f.setAccessible(true);
                        Context c = (Context) f.get(self);
                        if (c != null) {
                            return c.getContentResolver();
                        }
                    }
                }
            } catch (Throwable ignored) {
            }
        }
        try {
            Class<?> at = Class.forName("android.app.ActivityThread");
            Application app = (Application) at.getMethod("currentApplication").invoke(null);
            if (app != null) {
                return app.getContentResolver();
            }
        } catch (Throwable ignored) {
        }
        return null;
    }

    /**
     * /sys/class/power_supply/battery/status holds text ("Charging",
     * "Discharging", "Full"), not a number, so it needs its own reader.
     * Returns the POWER_SUPPLY_STATUS_* code, or -1 when unreadable.
     */
    private static int readSysfsStatus(String path) {
        try {
            java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(path));
            String line = r.readLine();
            r.close();
            if (line == null) {
                return -1;
            }
            line = line.trim();
            if (line.equalsIgnoreCase("Charging")) {
                return 2;
            }
            if (line.equalsIgnoreCase("Discharging")) {
                return 3;
            }
            if (line.equalsIgnoreCase("Full")) {
                return 5;
            }
            if (line.equalsIgnoreCase("Not charging")) {
                return 4;
            }
            return -1;
        } catch (Throwable ignored) {
            return -1;
        }
    }

    private static int readSysfsInt(String path, int def) {
        try {
            java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(path));
            String line = r.readLine();
            r.close();
            return line != null ? Integer.parseInt(line.trim()) : def;
        } catch (Throwable ignored) {
            return def;
        }
    }

    /** Settings.Global lookup; any failure -> fail-safe default. */
    private static int globalInt(ContentResolver cr, String key, int def) {
        if (cr == null) {
            return def;
        }
        try {
            return Settings.Global.getInt(cr, key, def);
        } catch (Throwable ignored) {
            return def;
        }
    }

    /**
     * system_server: intercept MiuiBatteryServiceImpl's shutdown decision.
     * We rewrite the battery level to 2 (ARM) while above the floor, and to 1
     * (RELEASE) at or below it, so the 30s countdown fires at the user's
     * voltage instead of the stock 3.4V.
     */
    static final class SystemShutdownHooker implements XposedInterface.Hooker {
        private volatile int lastOutcome = -1;
        private volatile boolean lastAboveFloor = true;  // start assuming above floor

        @Override
        public Object intercept(XposedInterface.Chain chain) throws Throwable {
            try {
                // system_server has no Application/ActivityThread; use
                // Settings.Global directly via the system process context.
                int enable = 1, floor = DEFAULT_FLOOR, guard = 1;
                long skip = 0L;
                try {
                    Class<?> sg = Class.forName("android.provider.Settings$Global");
                    android.content.Context ctx = getSystemContext();
                    if (ctx != null) {
                        android.content.ContentResolver cr = ctx.getContentResolver();
                        enable = (Integer) sg.getMethod("getInt", android.content.ContentResolver.class, String.class, int.class)
                                .invoke(null, cr, KEY_ENABLE, 1);
                        floor = (Integer) sg.getMethod("getInt", android.content.ContentResolver.class, String.class, int.class)
                                .invoke(null, cr, KEY_FLOOR, DEFAULT_FLOOR);
                        guard = (Integer) sg.getMethod("getInt", android.content.ContentResolver.class, String.class, int.class)
                                .invoke(null, cr, KEY_PC_GUARD, 1);
                        // Settings.Global is public API -- no reflection needed,
                        // and getLong keeps the epoch-seconds value in range
                        // (an int would overflow in 2038).
                        skip = Settings.Global.getLong(cr, KEY_SHUT_SKIP, 0L);
                    }
                } catch (Throwable t) {
                    android.util.Log.w("VcutHook", "sys_shutdown settings read failed: " + t);
                }

                if (enable == 0 || guard == 0) {
                    return chain.proceed();
                }

                // Read the real voltage from sysfs (system_server can).
                // voltage_now is in microvolts (uV); convert to millivolts.
                int uv = readSysfsInt("/sys/class/power_supply/battery/voltage_now", 0);
                int mv = uv > 100000 ? uv / 1000 : uv;
                int status = readSysfsStatus("/sys/class/power_supply/battery/status");

                // Check if this is a SHUTDOWN_DELAY message (what == 7)
                java.util.List<Object> args = chain.getArgs();
                boolean isShutdownDelayEvent = false;
                if (args != null && args.size() >= 1) {
                    Object msg = args.get(0);
                    if (msg instanceof android.os.Message) {
                        isShutdownDelayEvent = ((android.os.Message) msg).what == 7;
                    }
                }

                int outcome;
                if (status == 2) {  // charging
                    outcome = 1;
                    lastAboveFloor = true;  // charging resets edge
                } else {
                    outcome = (mv > 0 && mv <= floor) ? 2 : 3;
                }

                if (outcome != lastOutcome) {
                    lastOutcome = outcome;
                    Log.i(TAG, "sys_shutdown outcome=" + outcome + " mv=" + mv
                            + " floor=" + floor + " status=" + status);
                }

                /*
                 * Shutdown-delay events are now decided by VOLTAGE, not
                 * blocked wholesale.
                 *
                 * The old code returned null for every case 7, which is why
                 * the countdown never appeared: the gauge emits
                 * POWER_SUPPLY_SHUTDOWN_DELAY=1 ONCE at its own 3310mV
                 * threshold (cell_voltage[2], not voltage_now), and after
                 * that bq28z610.c's
                 *   if (last_shutdown_delay != bq->shutdown_delay || ...)
                 * never fires again.  Swallowing the only event left the
                 * kernel and the framework both silent, so nothing could
                 * ever trigger at the user's vcut_delay.
                 *
                 * The ko (vcut_lower.c shut_tick) now re-emits the pair
                 * 0-then-1 every time the pack falls below vcut_delay, so
                 * pass 1 through when we are actually below the floor, and
                 * keep suppressing it above the floor (where the gauge's
                 * 3310mV edge would fire ~200mV too early).
                 */
                if (isShutdownDelayEvent) {
                    java.util.List<Object> a2 = chain.getArgs();
                    Object m2 = (a2 != null && !a2.isEmpty()) ? a2.get(0) : null;
                    int arg1 = (m2 instanceof android.os.Message)
                            ? ((android.os.Message) m2).arg1 : -1;
                    boolean belowFloor = mv > 0 && mv <= floor;
                    // 闩锁现在存到期时刻（epoch 秒）；窗口外等于没按过。
                    boolean skipped = skip > 0 && (System.currentTimeMillis() / 1000L) < skip;

                    /*
                     * arg1 == 0 MUST always pass through.  MiuiBatteryServiceImpl
                     * :1184 drops a value equal to mLastShutdownDelay, so the
                     * ko's 0 is what resets that latch before its 1.  Swallowing
                     * the 0 here would leave mLastShutdownDelay at 1 and the
                     * following 1 would be discarded as a duplicate -- the
                     * exact silent failure this work exists to remove.
                     */
                    if (arg1 == 0) {
                        Log.i(TAG, "sys_shutdown pass reset: mv=" + mv
                                + " floor=" + floor + " status=" + status);
                        return chain.proceed();
                    }
                    /*
                     * 用户按了"临时取消本次关机"：这一轮里连原厂那次
                     * 3310mV 的 1 也不放行，否则倒计时还是会起来。
                     * ko 的 shut_tick 同样被闩住并在需要时补发了 0。
                     * 只取消这一次，闩锁由 ko 在电压回到闸以上或插上
                     * 充电器时自动清掉，之后完全回到系统自己的判定。
                     */
                    if (skipped) {
                        Log.i(TAG, "sys_shutdown skipped by user: arg1=" + arg1
                                + " mv=" + mv + " floor=" + floor + " status=" + status);
                        return null;
                    }
                    if (arg1 == 1 && belowFloor && status != 2) {
                        Log.i(TAG, "sys_shutdown pass native event: mv=" + mv
                                + " floor=" + floor + " status=" + status);
                        return chain.proceed();
                    }
                    Log.i(TAG, "sys_shutdown blocked native event: arg1=" + arg1
                            + " mv=" + mv + " floor=" + floor + " status=" + status);
                    return null;
                }

                // On non-shutdown-delay battery events, check for falling edge
                // and inject our own broadcast when voltage <= floor
                if (outcome == 2 && lastAboveFloor) {
                    lastAboveFloor = false;
                    Log.i(TAG, "sys_shutdown falling edge: mv=" + mv + " floor=" + floor);
                    // Inject the broadcast via the outer MiuiBatteryServiceImpl
                    try {
                        Object thiz = chain.getThisObject();
                        if (thiz != null) {
                            // BatteryHandler is an inner class; the field that
                            // holds its outer MiuiBatteryServiceImpl is named
                            // this$0 today and something else after a rebuild.
                            // RULE 2: resolve it by TYPE (synthetic enclosing
                            // reference), not by name.
                            Object outer = outerOf(thiz);
                            if (outer != null) {
                                /*
                                 * sendStickyBroadcast is PRIVATE
                                 * (MiuiBatteryServiceImpl.java:2441), so
                                 * getMethod() can never find it -- every
                                 * previous attempt threw NoSuchMethodException
                                 * and was swallowed.  Its body is just:
                                 *   intent.addFlags(822083584);
                                 *   mContext.sendStickyBroadcastAsUser(intent, ALL);
                                 * so prefer mContext directly and keep the
                                 * declared-method call as a fallback.
                                 */
                                android.content.Intent intent = new android.content.Intent(
                                    "miui.intent.action.ACTION_SHUTDOWN_DELAY");
                                intent.putExtra("miui.intent.extra.shutdown_delay", 1);
                                intent.addFlags(0x31000000);
                                boolean sent = false;
                                try {
                                    // RULE 2: mContext is a field name, not a
                                    // contract.  Take any Context-typed field
                                    // on the outer service instance.
                                    android.content.Context ctx =
                                        (android.content.Context) fieldOfType(outer, android.content.Context.class);
                                    if (ctx != null) {
                                        /*
                                         * UserHandle.ALL is a hidden API and
                                         * does not compile against the public
                                         * SDK; Process.myUserHandle() is the
                                         * public equivalent for the process
                                         * we are already running as.
                                         */
                                        ctx.sendStickyBroadcastAsUser(intent,
                                            android.os.Process.myUserHandle());
                                        sent = true;
                                    }
                                } catch (Throwable ignored) {
                                }
                                if (!sent) {
                                    java.lang.reflect.Method sendBroadcast =
                                        outer.getClass().getDeclaredMethod(
                                            "sendStickyBroadcast", android.content.Intent.class);
                                    sendBroadcast.setAccessible(true);
                                    sendBroadcast.invoke(outer, intent);
                                }
                                Log.i(TAG, "sys_shutdown injected synthetic delay broadcast");
                            } else {
                                Log.w(TAG, "sys_shutdown outer MiuiBatteryServiceImpl is null");
                            }
                        }
                    } catch (Throwable t) {
                        /*
                         * Restore the edge flag on failure.  Leaving it false
                         * after a failed inject meant the falling edge was
                         * consumed and never retried, which is the other half
                         * of "after unplugging it never triggers again".
                         */
                        lastAboveFloor = true;
                        Log.w(TAG, "sys_shutdown inject failed: " + t);
                    }
                } else if (outcome == 3) {
                    lastAboveFloor = true;
                }

                return chain.proceed();
            } catch (Throwable t) {
                Log.w(TAG, "sys_shutdown error: " + t, t);
                return chain.proceed();
            }
        }
    }

    static final class G0Hooker implements XposedInterface.Hooker {
        private volatile int lastOutcome = -1;

        @Override
        public Object intercept(XposedInterface.Chain chain) throws Throwable {
            try {
                List<Object> args = chain.getArgs();
                if (!args.isEmpty() && args.get(0) instanceof Intent) {
                    Intent src = (Intent) args.get(0);
                    ContentResolver cr = resolver(chain.getThisObject());

                    int enable = globalInt(cr, KEY_ENABLE, 1);
                    int floor = globalInt(cr, KEY_FLOOR, DEFAULT_FLOOR);
                    int guard = globalInt(cr, KEY_PC_GUARD, 1);
                    int mv = src.getIntExtra("voltage", 0);   // mV
                    int status = src.getIntExtra("status", -1);

                    if (floor < 2500 || floor > 3400) {
                        floor = DEFAULT_FLOOR;
                    }

                    int level;
                    int outcome;
                    if (enable == 0) {
                        return chain.proceed();                 // explicitly disabled
                    } else if (guard == 0 || status == 2) {
                        level = ARM_LEVEL;                     // never trigger
                        outcome = 1;
                    } else if (mv > 0 && mv <= floor && status == 3) {
                        level = RELEASE_LEVEL;                 // falling edge -> 30s
                        outcome = 2;
                    } else {
                        level = ARM_LEVEL;                     // above floor / unknown
                        outcome = 3;
                    }

                    if (outcome != lastOutcome) {
                        lastOutcome = outcome;
                        Log.i(TAG, "guard outcome=" + outcome + " level=" + level
                                + " mv=" + mv + " floor=" + floor + " status=" + status
                                + " cr=" + (cr != null));
                    }

                    Intent patched = new Intent(src);
                    patched.putExtra("level", level);
                    Object[] newArgs = args.toArray();
                    newArgs[0] = patched;
                    return chain.proceed(newArgs);
                }
            } catch (Throwable t) {
                Log.w(TAG, "guard error: " + t, t);
            }
            // Fail-safe: never let an exception disable the guard completely.
            try {
                List<Object> args = chain.getArgs();
                if (!args.isEmpty() && args.get(0) instanceof Intent) {
                    Intent patched = new Intent((Intent) args.get(0));
                    patched.putExtra("level", ARM_LEVEL);
                    Object[] newArgs = args.toArray();
                    newArgs[0] = patched;
                    return chain.proceed(newArgs);
                }
            } catch (Throwable ignored) {
            }
            return chain.proceed();
        }
    }

    /** API 102 defaults to false; explicitly allow hot reload. */
    @Override
    public boolean onHotReloading(HotReloadingParam param) {
        return true;
    }

    /**
     * Package lifecycle callbacks are NOT replayed after hot reload, and the
     * default implementation unhooks every old hook.  Re-attach the new code
     * atomically via replaceHook() so the guard never has a gap.
     */
    @Override
    public void onHotReloaded(HotReloadedParam param) {
        boolean replaced = false;
        for (XposedInterface.HookHandle h : param.getOldHookHandles()) {
            if (HOOK_ID.equals(h.getId())) {
                try {
                    h.replaceHook(new G0Hooker());
                    replaced = true;
                } catch (Throwable t) {
                    log(Log.WARN, TAG, "replaceHook failed: " + t, t);
                }
            }
        }
        hooked = replaced;
        log(Log.INFO, TAG, "hot reloaded, hook replaced=" + replaced);
    }
}
