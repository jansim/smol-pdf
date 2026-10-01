/* jconfigint.h for the vendored mozjpeg (see scripts/vendor-deps.sh). */
#define BUILD  "smol-pdf"
#undef inline
#define INLINE  __inline__ __attribute__((always_inline))
#define THREAD_LOCAL  __thread
#define PACKAGE_NAME  "mozjpeg"
#define VERSION  "4.1.5"
#define SIZEOF_SIZE_T  __SIZEOF_SIZE_T__
#define HAVE_BUILTIN_CTZL
#if defined(__has_attribute)
#if __has_attribute(fallthrough)
#define FALLTHROUGH  __attribute__((fallthrough));
#else
#define FALLTHROUGH
#endif
#else
#define FALLTHROUGH
#endif
