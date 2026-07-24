#!/usr/bin/env bash
set -euo pipefail

project_root="$(git rev-parse --show-toplevel)"
skill_root="${project_root}/.agents/skills"
assisted_doc="${project_root}/docs/desarrollo-asistido.md"
expected_skills=(reefops-change reefops-domain-module reefops-gitops-change)

test -s "${project_root}/AGENTS.md"
test -s "${project_root}/.codex/config.toml"

for skill_name in "${expected_skills[@]}"; do
  skill_dir="${skill_root}/${skill_name}"
  skill_file="${skill_dir}/SKILL.md"
  metadata_file="${skill_dir}/agents/openai.yaml"

  test -d "${skill_dir}"
  test -s "${skill_file}"
  test -s "${metadata_file}"
  grep -q "^name: ${skill_name}$" "${skill_file}"
  grep -Eq '^description: .+' "${skill_file}"
  grep -q "\`${skill_name}\`" "${assisted_doc}"
  yq -e '.interface.display_name != null' "${metadata_file}" >/dev/null
  yq -e '.interface.short_description != null' "${metadata_file}" >/dev/null
  skill_invocation="\$${skill_name}"
  SKILL_INVOCATION="${skill_invocation}" \
    yq -e '.interface.default_prompt | contains(strenv(SKILL_INVOCATION))' \
    "${metadata_file}" >/dev/null

  if rg -n 'TODO|\[TODO' "${skill_dir}" >/dev/null; then
    echo "La skill ${skill_name} contiene marcadores pendientes." >&2
    exit 1
  fi
done

python3.12 - "${project_root}" <<'PY'
import pathlib
import sys
import tomllib

root = pathlib.Path(sys.argv[1])
config_path = root / ".codex/config.toml"
with config_path.open("rb") as stream:
    config = tomllib.load(stream)
assert config["agents"]["enabled"] is True
assert config["agents"]["max_concurrent_threads_per_session"] == 3

expected = {"architecture_reviewer", "gitops_reviewer", "traceability_reviewer"}
found = set()
for path in sorted((root / ".codex/agents").glob("*.toml")):
    with path.open("rb") as stream:
        agent = tomllib.load(stream)
    assert agent["sandbox_mode"] == "read-only", path
    assert agent["name"] not in found, agent["name"]
    found.add(agent["name"])
assert found == expected, (found, expected)
print(f"Configuración Codex validada: 1 config y {len(found)} agentes.")
PY

echo "Ayudas Codex validadas."
