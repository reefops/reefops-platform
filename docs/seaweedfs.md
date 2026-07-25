# SeaweedFS local

## Alcance

Esta raíz reusable instala el backend S3 de development en `reefops-data`.
SeaweedFS es plataforma, no una fuente funcional ni un dominio. El contrato de
producto está en `reefops/docs/almacenamiento-objetos.md`.

La composición se separa en tres reconciliaciones:

1. `seaweedfs-secret` entrega la configuración S3 desde OpenBao mediante ESO;
2. `seaweedfs-stack` instala master, volume, filer y S3 cuando el Secret existe;
3. `seaweedfs-config` añade observabilidad y políticas de red después del stack.

La separación impide que Helm arranque con autenticación vacía y evita aplicar
recursos `ServiceMonitor` antes de que sus CRD estén preparadas.

## Topología de development

| Rol | Réplicas | Persistencia inicial |
|---|---:|---:|
| master | 1 | 1 GiB |
| filer con LevelDB2 | 1 | 2 GiB |
| volume | 1 | 20 GiB |
| S3 | 1 | sin PVC propio |

Todos los PVC usan `reefops-hostpath-retain`, una StorageClass IaC dedicada
sobre el provisioner de Docker Desktop, RWO y `reclaimPolicy: Retain`. La
anotación Helm evita que un uninstall normal pode el PVC y la política efectiva
del PV evita que borrar accidentalmente el claim destruya el volumen. Ninguna
de las dos protege frente a un reset de Docker Desktop. La capacidad inicial
preserva margen en el disco del Mac mini y no constituye un límite funcional
definitivo. El provisioner no permite expansión; un aumento requiere
exportación, recreación controlada y restauración.

Se usa colocación `000`: ninguna réplica adicional en el mismo host se presenta
como HA. Los servicios son `ClusterIP` y no se crea Ingress, `NodePort`,
`LoadBalancer`, acceso anónimo ni bucket funcional.

Los contenedores ejecutan la imagen oficial fijada por digest, sin escalado de
privilegios, con seccomp y capabilities eliminadas. No montan tokens de
ServiceAccount y el chart no crea ClusterRole. La aceptación debe demostrar que
la versión fijada funciona con UID no root y Pod Security `restricted`.

## Cadena de suministro

Upstream publica el chart `seaweedfs` 4.39.0 mediante un repositorio Helm HTTP.
Su índice declara:

- paquete:
  `https://seaweedfs.github.io/seaweedfs/helm/seaweedfs-4.39.0.tgz`;
- SHA-256 upstream:
  `dbecd4c1f3cd5ae2eac62f3a0ccd92c05c1b05a20bd2b5f574c1e69dec440da2`;
- aplicación 4.39;
- imagen multi-arquitectura:
  `docker.io/chrislusf/seaweedfs@sha256:c7d6c721b30ae711db766bbbfd40192776e263d4e51e22f57baef7bef93c12c6`.

`mirror-seaweedfs-chart.sh` descarga a un directorio temporal, verifica el
digest upstream y publica el paquete sin modificar en
`ghcr.io/reefops/seaweedfs`. La raíz Flux consume ese artefacto OCI por
digest, no el índice HTTP ni un tag flotante. La promoción registra ambos
digests para conservar procedencia.

## Credenciales

`task seaweedfs-credentials-bootstrap` es una ceremonia create-once contra el
OpenBao activo. El wrapper fija contexto `docker-desktop`, namespace, CA, SNI,
Service y `cluster_id`; no acepta un endpoint arbitrario. Si la ruta ya existe
no rota ni revela el valor.

La operación genera access key y secret key con entropía local y escribe sólo:

```text
platform/seaweedfs/s3
```

Una política OpenBao dedicada permite leer exclusivamente esa ruta a un rol
Kubernetes ligado al ServiceAccount ESO de `reefops-data`. ESO compone
`seaweedfs_s3_config` en el Secret objetivo sin versionar valores. Ni la
evidencia ni las comprobaciones imprimen el Secret.

Rotar credenciales será una operación posterior de doble credencial: añadir la
nueva identidad, comprobar consumidores, retirar la anterior y conservar una
cadena causal única. La primera fase no automatiza una rotación destructiva.

## Red y observabilidad

La política de red permite:

- tráfico entre componentes SeaweedFS dentro de `reefops-data`;
- S3 desde namespaces y pods etiquetados expresamente cuando existan;
- scrape de métricas desde `reefops-observability`;
- DNS y egress internos indispensables.

Pertenecer al entorno no concede acceso S3. La prueba local usa un port-forward
autenticado por Kubernetes, que no supone exposición norte-sur.

Prometheus recoge master, volume, filer y S3. Las alertas iniciales cubren
componente ausente, PVC próximo a agotarse y errores del contrato periódico.
Grafana muestra salud, capacidad y tasas técnicas; no sustituye la auditoría
funcional de accesos a medios.

## Aceptación

`task seaweedfs-verify` exige antes de mutar:

- `main` local, fuente Flux y reconciliaciones en revisiones exactas;
- HelmRelease, ExternalSecret y todos los pods preparados;
- chart OCI e imagen con los digests declarados;
- servicios internos y ausencia de recursos de exposición;
- PVC enlazados y credencial procedente de ESO/OpenBao.

La revisión GitOps se obtiene de la API Kubernetes del `GitRepository` de Flux.
No se usa la salida de presentación de `flux get`: su formato y opciones no son
un contrato estable para automatización. Esta comprobación cubre la regresión
detectada durante la primera aceptación, cuando `flux get source git -o json`
falló antes de comenzar las pruebas S3.

Después crea un bucket y objetos sintéticos, valida el subconjunto S3, reinicia
los cuatro roles y confirma persistencia. El trap elimina bucket, port-forward
y temporales incluso al fallar. Cada fase registra revisión, recursos, actor,
autorización, entorno, correlación, causación, checksums y resultado, nunca
credenciales ni payload privado.

## Backup y restore

`task seaweedfs-recovery-verify` crea únicamente un objeto sintético, exporta
contenido, metadata, tags e inventario, cifra artefacto y manifiesto con `age`
antes de escribirlos en el QNAP, elimina la fuente, restaura en otro bucket y
compara checksums y metadata. Nunca sobrescribe un bucket existente y destruye
ambos buckets de ensayo al finalizar.

Este ensayo demuestra portabilidad lógica de objetos dentro del proveedor
activo; no demuestra disaster recovery tras perder los PV o la VM de Docker
Desktop. Esa garantía seguirá abierta hasta restaurar el artefacto en una
instancia SeaweedFS vacía e independiente. Por tanto, su éxito es gate del
contrato de backup lógico, no de recuperabilidad completa del host.

El gate inicial demuestra así el mecanismo sin dar acceso a datos reales. Las
tareas genéricas de backup exigirán una allowlist explícita de buckets y se
activarán cuando exista el primer bucket funcional. Este ensayo no convierte
un único Mac en HA ni garantiza todavía el RPO de datos reales. Cuando exista
PostgreSQL, ambos runbooks incorporarán un identificador de consistencia
coordinado.
