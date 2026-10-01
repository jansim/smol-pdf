/* qpdf-config.h for the vendored qpdf (see scripts/vendor-deps.sh), for macOS and Linux. */
#define DEFAULT_CRYPTO "native"
#define USE_CRYPTO_NATIVE 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_FSEEKO 1
#define HAVE_LOCALTIME_R 1
#define HAVE_RANDOM 1
#define HAVE_OPEN_MEMSTREAM 1
#if defined(__APPLE__)
# define HAVE_TM_GMTOFF 1
#else
# define HAVE_EXTERN_LONG_TIMEZONE 1
#endif
#define SIZEOF_SIZE_T __SIZEOF_SIZE_T__
