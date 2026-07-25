# Fundación inerte de Envoy Gateway

## Alcance

Esta etapa instala Envoy Gateway 1.8.3 y las CRD compatibles incluidas en su
chart oficial. No instala `GatewayClass`, `Gateway`, rutas ni plano de datos.
La entrada protegida pertenece a una etapa posterior.

El chart OCI queda fijado a
`sha256:cfb34ff4266c87a394cd6be5c13607a2dd47083aef771368302eaeaa99c4a0a9`
y la imagen multi-arquitectura del controlador a
`sha256:e7a8c70537628bf996e5dec5c4c835704b4b9f4f715a74cf361bea30608c49ac`.
La imagen latente de rate-limit también queda fijada a
`sha256:5bb3741fd6709bab1d498eae1a5807faa2113b712dfb236fb76c04a00871ffc9`;
no se desplegará hasta que una política posterior la necesite.

## Aislamiento

- El controlador vive en `reefops-gateway-system`, con Pod Security
  `restricted`.
- Usa `GatewayNamespace` y observa explícitamente solo su propio namespace.
  Añadir un namespace es una decisión GitOps revisable.
- El topology injector está desactivado hasta necesitarlo.
- El servicio de control es `ClusterIP`.
- Una NetworkPolicy deniega toda entrada salvo las métricas desde
  `reefops-observability`.
- El controlador y el job de certificados ejecutan sin root, sin elevación,
  sin capacidades y con seccomp.
- El chart gestiona las CRD con `CreateReplace`; una actualización requiere
  revisar migración y compatibilidad antes del PR.

El ClusterRole conserva únicamente recursos cluster-scoped: namespaces, nodes,
GatewayClass, ServiceImport y TokenReview. Secrets, Services, workloads, rutas
y políticas se observan mediante Roles dentro del namespace allowlisted.

## Reconciliación

Flux aplica dos raíces:

1. `reefops-envoy-gateway-stack`: OCIRepository, HelmRelease, CRD y
   controlador;
2. `reefops-envoy-gateway-config`: NetworkPolicy y ServiceMonitor, dependiente
   del stack.

No se agregan al `platform/kustomization.yaml`, porque esa raíz no puede
representar el orden entre ambas.

## Aceptación

Después de promocionar el commit exacto en `reefops-gitops`, ejecutar:

```sh
task envoy-gateway-verify
```

La prueba exige `main` limpio y la misma revisión en Git, la fuente de Flux y
la reconciliación de entorno y ambas Kustomizations de Envoy. Comprueba CRD
establecidas, Deployment preparado,
digests, hardening, métricas visibles y ausencia global de Gateway, rutas,
Ingress, Envoy data plane, NodePort y LoadBalancer. Registra el resultado en
una cadena JSONL local sin secretos.

La cadena se respalda y verifica con:

```sh
task envoy-gateway-evidence-backup
task envoy-gateway-evidence-backup-verify
```

El backup se cifra antes de escribirse en el destino externo y su manifiesto
cifrado fija hashes, recuento y retención mínima de 365 días.

Esta aceptación no prueba tráfico norte-sur porque crear dicho tráfico violaría
el alcance de la etapa.
