# The app uses no reflection. JNI resolves WhisperNative's native methods by name, so R8 must keep
# them (and the class name) as they are.
-keepclasseswithmembernames,includedescriptorclasses class com.justspeaktoit.android.local.WhisperNative {
    native <methods>;
}
