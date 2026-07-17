// Fleet policy (SPEC §6.2 item 15): leaks are not what this target fuzzes for. ASan bundles LSan,
// and this build-time hook is the only reliable way to turn just LeakSanitizer off.
extern "C" int __lsan_is_turned_off() { return 1; }
