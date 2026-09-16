-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class io.flutter.embedding.** { *; }

-keep class com.videoplatform.mobile_app.** { *; }

-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses

-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

-keep,allowobfuscation,allowshrinking class * extends com.google.gson.TypeAdapter
-keep,allowobfuscation,allowshrinking class * implements com.google.gson.TypeAdapterFactory
-keep,allowobfuscation,allowshrinking class * implements com.google.gson.JsonSerializer
-keep,allowobfuscation,allowshrinking class * implements com.google.gson.JsonDeserializer

-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
-dontwarn org.codehaus.mojo.animal_sniffer.IgnoreJRERequirement
