# Release builds minify by default. Pigeon JNI resolves Kotlin suspend
# methods by the original descriptor, including kotlin.coroutines.Continuation.
# R8 renamed that interface to n4.c, so SharedPreferencesApiRegistrar.getAll
# no longer matched and startup failed while reading preferences.
-keep class kotlin.coroutines.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
