# gomobile 生成的桥接类是按**字符串名字**被 Go 侧反射调用的：
#   FindClass("go/Seq") / FindClass("gx/Seq")
#   GetMethodID(..., "getRef"/"incRefnum"/"decRef"/"incGoObjectRef", ...)
# 所以这些包必须整体保留（类名、方法名、内部类都不能动），否则 Go 侧查不到
# 就会 abort，整个进程直接崩（表现为"内核连续 N 次启动失败"）。
#
# 两个 AAR 各自带了 consumer 规则，这里再兜一层：万一以后重新打 AAR 时漏改
# proguard.txt，也不会静默退化成一个必然崩溃的包。
-keep class go.** { *; }
-keep class gx.** { *; }
-keep class openlistcore.** { *; }
-keep class libXray.** { *; }
