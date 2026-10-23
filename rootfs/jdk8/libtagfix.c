/*
 * Loaded by OpenJDK 8's bin/java before anything else (build.sh adds it to what java links): turns
 * bionic's heap pointer tagging off. Android 11+ tags the top byte of what malloc returns on 64-bit
 * ARM, and HotSpot 8's code generator can't encode such addresses ("Field too big for insn"). Pointers
 * tagged before stay valid; from here on, none are. Elsewhere (32-bit ABIs, x86) there's nothing to turn off.
 */
extern int mallopt(int param, int value);

#define M_BIONIC_SET_HEAP_TAGGING_LEVEL (-204)
#define M_HEAP_TAGGING_LEVEL_NONE 0

__attribute__((constructor)) static void no_heap_tagging(void) {
    mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE);
}
