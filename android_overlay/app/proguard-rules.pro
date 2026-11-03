# gomobile bindings (AndroidLibXrayLite) are looked up by name from native code.
-keep class libv2ray.** { *; }
-keep class go.** { *; }
-dontwarn go.**
-dontwarn libv2ray.**
-keepclasseswithmembernames class * { native <methods>; }
