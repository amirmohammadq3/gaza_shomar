# قوانین مورد نیاز برای GSON که پکیج flutter_local_notifications
# برای ذخیره و زمان‌بندی اعلان‌ها از آن استفاده می‌کند. بدون این قوانین،
# در بیلد ریلیز (minifyEnabled) ممکن است زمان‌بندی اعلان‌ها به‌درستی کار نکند.

-keepattributes Signature
-keepattributes *Annotation*

-dontwarn sun.misc.**
-keep class com.google.gson.stream.** { *; }

-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# کلاس‌های خود پکیج flutter_local_notifications
-keep class com.dexterous.** { *; }
