#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
requirements_file="${project_root}/docs/requisitos-funcionales.md"
alignment_file="${project_root}/docs/alineacion-requisitos-arquitectura.md"
requirements_ids="$(mktemp)"
alignment_ids="$(mktemp)"
trap 'rm -f "${requirements_ids}" "${alignment_ids}"' EXIT

rg -o 'RF-[0-9]+[A-Z]?' "${requirements_file}" | sort -u >"${requirements_ids}"
rg -o 'RF-[0-9]+[A-Z]?' "${alignment_file}" | sort -u >"${alignment_ids}"

if ! diff -u "${requirements_ids}" "${alignment_ids}"; then
  echo "La matriz de alineación no cubre exactamente los requisitos." >&2
  exit 1
fi

echo "Cobertura RF validada: $(wc -l <"${requirements_ids}" | tr -d ' ') requisitos."

