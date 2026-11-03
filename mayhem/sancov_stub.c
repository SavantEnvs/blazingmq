#include <stdint.h>
void __sanitizer_cov_8bit_counters_init(char *s, char *e) { (void)s; (void)e; }
void __sanitizer_cov_pcs_init(const uintptr_t *s, const uintptr_t *e) { (void)s; (void)e; }
void __sanitizer_cov_trace_cmp1(uint8_t a, uint8_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp2(uint16_t a, uint16_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp4(uint32_t a, uint32_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_cmp8(uint64_t a, uint64_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp1(uint8_t a, uint8_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp2(uint16_t a, uint16_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp4(uint32_t a, uint32_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_const_cmp8(uint64_t a, uint64_t b) { (void)a; (void)b; }
void __sanitizer_cov_trace_switch(uint64_t v, uint64_t *c) { (void)v; (void)c; }
void __sanitizer_cov_trace_div4(uint32_t v) { (void)v; }
void __sanitizer_cov_trace_div8(uint64_t v) { (void)v; }
void __sanitizer_cov_trace_gep(uintptr_t i) { (void)i; }
