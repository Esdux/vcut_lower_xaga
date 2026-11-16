-repackageclasses
# LSPosed 入口类不能被混淆，也不能被 -repackageclasses 挪到默认包
-keep class com.xaga.vcut.hook.VcutHook { *; }
-keep class com.xaga.vcut.hook.VcutHook$* { *; }
