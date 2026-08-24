#ifndef BBR_RE2_H_
#define BBR_RE2_H_

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BbrRegex BbrRegex;

enum {
  BBR_REGEX_OUT_OF_MEMORY = -1,
  BBR_RE2_ERROR_PATTERN_TOO_LARGE = 15,
};

BbrRegex *bbr_regex_compile(
    const char *pattern,
    size_t pattern_len,
    int *error_code,
    char *error_fragment,
    size_t error_fragment_capacity,
    size_t *error_fragment_len);
bool bbr_regex_match(const BbrRegex *regex, const char *text, size_t text_len);
void bbr_regex_delete(BbrRegex *regex);

#ifdef __cplusplus
}
#endif

#endif
