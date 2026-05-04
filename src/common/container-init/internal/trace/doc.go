// Package trace emits boot-trace JSONL records compatible with the
// existing kasm-boot-trace.jsonl format. Gated on CONTAINER_INIT_TRACE=1;
// path defaults to ${CONTAINER_INIT_TRACE_FILE:-/tmp/container-init-trace.jsonl}.
package trace
