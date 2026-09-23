# Stacktrace fixtures

`ruby.txt` transcribes five complete frames visible in the user's screenshot,
with its absolute gem installation prefix replaced by `@ROOT@/gems`. Cropped
frames are intentionally omitted. `v8.txt` and `java.txt` are synthetic examples
of standard V8 and JVM stack syntax. Tests substitute a temporary local root.
