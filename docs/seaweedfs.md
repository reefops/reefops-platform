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

Todos los PVC usan `hostpath`, RWO y `Retain` en el HelmRelease. La capacidad
inicial preserva margen en el disco del Mac mini y no constituye un límite
funcional definitivo. Docker Desktop no permite expansión de esa StorageClass;
un aumento requiere exportación, recreación controlada y restauración.

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
`ghcr.io/reefops/charts/seaweedfs`. La raíz Flux consume ese artefacto OCI por
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

Después crea un bucket y objetos sintéticos, valida el subconjunto S3, reinicia
los cuatro roles y confirma persistencia. El trap elimina bucket, port-forward
y temporales incluso al fallar. Cada fase registra revisión, recursos, actor,
autorización, entorno, correlación, causación, checksums y resultado, nunca
credenciales ni payload privado.

## Backup y restore

`task seaweedfs-backup` exporta únicamente una allowlist explícita de buckets,
genera inventario y checksums, cifra el artefacto con `age` antes de copiarlo al
QNAP y elimina el staging en claro. `task seaweedfs-verify-backup` valida
estructura, manifest y cadena sin restaurar datos activos.

`task seaweedfs-restore-verify` exige un bucket de destino aislado y el digest
esperado, restaura, compara contenido y metadata y destruye el bucket de
ensayo. Nunca sobrescribe un bucket existente ni modifica el desired state.

El gate inicial usa sólo datos sintéticos. Su éxito demuestra el mecanismo,
pero no convierte un único Mac en HA ni garantiza todavía el RPO de datos
reales. Cuando exista PostgreSQL, ambos runbooks incorporarán un identificador
de consistencia coordinado.
