// Package unit parses systemd unit files into the container-init subset
// type, validates them against the Kasm-subset rules, and resolves
// ${VAR} / ${VAR:-default} expansion on directive values.
package unit
