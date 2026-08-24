#include "bbr_re2.h"

#include <algorithm>
#include <cstring>
#include <new>

#include "re2/re2.h"

struct BbrRegex {
  RE2 regex;

  explicit BbrRegex(absl::string_view pattern, const RE2::Options &options)
      : regex(pattern, options) {}
};

extern "C" BbrRegex *bbr_regex_compile(
    const char *pattern,
    size_t pattern_len,
    int *error_code,
    char *error_fragment,
    size_t error_fragment_capacity,
    size_t *error_fragment_len) {
  RE2::Options options;
  options.set_encoding(RE2::Options::EncodingUTF8);
  options.set_posix_syntax(false);
  options.set_case_sensitive(true);
  options.set_log_errors(false);
  options.set_never_capture(true);
  options.set_longest_match(false);
  options.set_dot_nl(false);
  options.set_never_nl(false);
  options.set_literal(false);
  options.set_max_mem(1024 * 1024);

  BbrRegex *compiled = new (std::nothrow)
      BbrRegex(absl::string_view(pattern, pattern_len), options);
  if (compiled == nullptr) {
    if (error_code != nullptr) *error_code = BBR_REGEX_OUT_OF_MEMORY;
    if (error_fragment_len != nullptr) *error_fragment_len = 0;
    return nullptr;
  }
  if (compiled->regex.ok()) {
    if (error_code != nullptr) *error_code = 0;
    if (error_fragment_len != nullptr) *error_fragment_len = 0;
    return compiled;
  }

  if (error_code != nullptr) *error_code = compiled->regex.error_code();
  const std::string &fragment = compiled->regex.error_arg();
  const size_t copied = std::min(fragment.size(), error_fragment_capacity);
  if (copied != 0 && error_fragment != nullptr) {
    std::memcpy(error_fragment, fragment.data(), copied);
  }
  if (error_fragment_len != nullptr) *error_fragment_len = copied;
  delete compiled;
  return nullptr;
}

extern "C" bool bbr_regex_match(
    const BbrRegex *regex, const char *text, size_t text_len) {
  return RE2::PartialMatch(absl::string_view(text, text_len), regex->regex);
}

extern "C" void bbr_regex_delete(BbrRegex *regex) { delete regex; }
