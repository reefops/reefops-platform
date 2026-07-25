# Bootstrap de infraestructura

Este directorio contiene la única entrada imperativa normal de ReefOps. Su
objetivo es conectar un Kubernetes vacío con el estado deseado almacenado en
Git. El bootstrap no instala aplicaciones de negocio directamente.

## Prerrequisitos

- Kubernetes accesible mediante un contexto explícito.
- Git, kubectl, Flux CLI, SOPS, age, OpenBao CLI, Helm y Task.
- Organización y tres repositorios Git remotos privados ya creados.
- Credenciales Git disponibles para Flux sin escribirlas en el repositorio.

## Variables

| Variable | Obligatoria | Descripción |
|---|---|---|
| `REEFOPS_GITHUB_OWNER` | Sí | Usuario u organización propietaria |
| `REEFOPS_GITHUB_REPOSITORY` | No | Repositorio; por defecto `reefops-gitops` |
| `REEFOPS_PLATFORM_REPOSITORY` | No | Repositorio; por defecto `reefops-platform` |
| `REEFOPS_GIT_BRANCH` | No | Rama; por defecto `main` |
| `REEFOPS_CLUSTER_CONTEXT` | No | Contexto; por defecto `docker-desktop` |
| `REEFOPS_CLUSTER_PATH` | No | Path Git; por defecto `infra/clusters/local` |
| `REEFOPS_AGE_KEY_FILE` | No | Clave age externa al repo |

Las credenciales requeridas por la URL se proporcionarán mediante el mecanismo
de autenticación de Git/Flux elegido. Nunca se pondrán en Taskfile, argumentos
versionados o archivos `.env` confirmados.

## Uso

```sh
task prerequisites
task validate
REEFOPS_GITHUB_OWNER=organizacion task platform-seed
REEFOPS_GITHUB_OWNER=organizacion task gitops-seed
REEFOPS_GITHUB_OWNER=organizacion task bootstrap
task status
```

El bootstrap se detiene si el contexto no coincide, el nodo no está preparado,
el repositorio GitOps no contiene `clusters/local/kustomization.yaml`, el
repositorio local no tiene commit o falta cualquier herramienta.
La detección de un bootstrap completo exige controladores, `GitRepository` y
`Kustomization` raíz. Si una ejecución se interrumpe entre esas fases, la
siguiente reanuda el bootstrap en lugar de aceptar el estado parcial.

`platform-seed` y `gitops-seed` solo admiten repositorios vacíos. El primero
publica componentes reutilizables; el segundo publica únicamente composición
privada por clúster y selección de aplicaciones. Ninguno sobrescribe o mezcla
un repositorio existente.

El root `clusters/local/workloads` de GitOps solo puede contener fuentes y
reconciliaciones hacia artefactos o repositorios fijados. Nunca referenciará
`infrastructure/` o `platform/` como directorios locales, porque pertenecen a
`reefops-platform`. La validación del seed reconstruye el layout remoto y lo
renderiza antes de autorizar bootstrap.
El reconciliador raíz solo orquesta y no espera la salud de los
reconciliadores hijos; así puede aplicar una promoción correctiva aunque una
capa esté degradada. Cada reconciliador hijo conserva `wait`, dependencias y
timeout propios.

OpenBao es la autoridad runtime. La política `.sops.yaml` solo protege material
de bootstrap y contiene identidad pública. La clave privada predeterminada
reside en `~/.config/reefops/age/keys.txt` y debe copiarse de forma segura a un
almacenamiento de recuperación externo.

Los secretos CI allowlisted se replican desde OpenBao con `task
ci-secret-sync`. El valor viaja directamente por `stdin` hacia `gh`; nunca se
guarda en una variable, argumento, fichero temporal o log.
