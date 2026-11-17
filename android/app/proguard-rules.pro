# The app uses no reflection. JNI resolves WhisperNative's and LlamaNative's native methods by name,
# so R8 must keep them (and the class names) as they are.
-keepclasseswithmembernames,includedescriptorclasses class com.justspeaktoit.android.local.WhisperNative {
    native <methods>;
}
-keepclasseswithmembernames,includedescriptorclasses class com.justspeaktoit.android.local.LlamaNative {
    native <methods>;
}
