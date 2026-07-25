# Gestión de secretos

## 1. Autoridad y alcance

OpenBao es la autoridad local para secretos runtime y credenciales de
automatización. Pertenece a plataforma, no a ningún dominio de negocio.

Se distinguen cuatro clases:

| Clase | Autoridad | Entrega |
|---|---|---|
| Runtime de workloads | OpenBao local | Identidad Kubernetes y volumen en memoria |
| Bootstrap de OpenBao/Flux | Custodia offline | SOPS + `age` solo cuando deba declararse cifrado |
| CI de GitHub | OpenBao local | Réplica revocable en GitHub Secrets |
| Datos, medios y backups | Almacén local correspondiente | Nunca GitHub Secrets |

Los servicios de dominio no importarán un SDK de OpenBao ni conocerán dónde se
custodia un secreto. La plataforma lo montará como archivo o lo entregará al
adaptador técnico correspondiente.

La NetworkPolicy solo permite clientes desde namespaces autorizados
explícitamente con `reefops.io/openbao-access=true`; pertenecer a ReefOps no
concede acceso lateral al gestor.

La deploy key de lectura de `reefops-gitops` es una credencial de bootstrap:
se genera localmente, se registra como read-only y se instala en `flux-system`.
Puede regenerarse y revocarse sin restaurar datos de OpenBao.

## 2. OpenBao local

OpenBao se desplegará mediante GitOps en el repositorio `reefops-platform`.
Usará almacenamiento persistente y audit device separado. En el Mac Mini
inicial se ejecutará como instancia standalone; esto no se presentará como alta
disponibilidad.

El almacenamiento será Raft integrado incluso con un único nodo. Raft aporta
snapshots verificables y un camino de evolución a varios nodos, pero un único
Mac Mini sigue siendo un único dominio de fallo. No se simulará alta
disponibilidad con varias réplicas sobre el mismo host.

OpenBao no expondrá HTTP en claro. cert-manager, instalado como componente de
plataforma independiente, mantendrá una CA local y un certificado interno para
`openbao.reefops-secrets.svc`. El trust root se distribuirá únicamente a
adaptadores y operadores autorizados. La clave de la CA vive como Secret
Kubernetes gestionado por cert-manager; su backup y rotación forman parte de la
recuperación de plataforma y nunca se copia a GitHub.
Las variables que el chart deriva de TLS no se redefinen en valores locales;
el render validado rechaza nombres de entorno duplicados antes de promocionar
OpenBao.
El nodo local no usa `service_registration "kubernetes"` ni permisos para
mutar pods: Kubernetes descubre el servicio estable y OpenBao mantiene el
mínimo RBAC posible. Tampoco conserva opciones HCL retiradas por la versión
fijada.

cert-manager renovará el certificado leaf, pero OpenBao solo relee sus ficheros
TLS mediante `SIGHUP`. La recarga será una operación local auditada que compara
el serial servido antes y después. La CA tendrá backup `age` independiente del
snapshot Raft. El certificado CA tiene una vigencia larga y se renueva con la
misma clave; la clave CA no rotará automáticamente. Su sustitución exige una
transición explícita de doble confianza.

Dependencias y orden:

1. namespace, almacenamiento y políticas de red;
2. cert-manager y sus CRD;
3. CA local y certificado TLS de OpenBao;
4. OpenBao;
5. inicialización y unseal mediante procedimiento local;
6. auth de Kubernetes y políticas de mínimo privilegio;
7. integración de entrega a workloads;
8. aplicaciones que consumen secretos.

Señales de salud:

- pod preparado;
- almacenamiento montado;
- certificado TLS vigente y verificado;
- instancia inicializada y no sellada;
- audit device operativo;
- login Kubernetes de prueba con permisos mínimos;
- lectura de una ruta sintética sin exponer su valor.

La configuración versionada crea dos identidades de Kubernetes sin tokens
montados permanentemente:

- `openbao-smoke-test`, limitada a los metadatos de `ci/healthcheck`;
- `openbao-backup`, limitada a obtener snapshots Raft.

Los logins solicitan tokens Kubernetes de corta duración y los canjean por
tokens OpenBao igualmente efímeros. El token inicial solo se utiliza para la
configuración de bootstrap y se devuelve inmediatamente a custodia offline.
Que Helm y Flux estén reconciliados no permite desbloquear consumidores si
falla cualquiera de estas pruebas.

La instalación Helm no espera readiness en el primer arranque porque una
instancia sellada no puede estar preparada antes de la inicialización manual.
Esta excepción solo cubre la instalación: ninguna aplicación consumidora se
desbloquea hasta comprobar `initialized`, `sealed=false`, audit y autenticación.

Fallo seguro:

- una instancia sellada impide entregar nuevos secretos;
- los consumidores no reciben valores vacíos ni defaults inseguros;
- no se reinicializa automáticamente;
- no se imprime unseal material en logs;
- una pérdida de OpenBao no se recupera mediante Git revert.

Recuperación:

- backup cifrado del almacenamiento fuera de la VM;
- backup de CA y metadatos de certificados conforme al runbook de plataforma;
- custodia offline de recovery/unseal material;
- restauración ensayada y documentada;
- rotación posterior de credenciales potencialmente expuestas;
- evidencia de actor, autorización, backup, versión y resultado.

El procedimiento ejecutable y sus comprobaciones se definen en
[Runbook de recuperación de OpenBao](runbooks/openbao-recuperacion.md).

Los StatefulSets conservarán sus PVC al eliminarse o escalarse. OpenBao usará
usuario no root, seccomp `RuntimeDefault`, privilege escalation deshabilitada,
capabilities mínimas y requests/limits explícitos. Un cambio de esos controles
deberá renderizarse y probarse antes de promoverse.

## 3. GitHub Secrets

Antes de crear un GitHub Secret se intentará, por este orden:

1. `GITHUB_TOKEN` con permisos mínimos;
2. OIDC y credencial efímera;
3. GitHub App;
4. deploy key restringida solo para GitOps; plataforma pública sin credencial;
5. réplica de un secreto de OpenBao.

La sincronización se ejecutará en el host local y siempre iniciará la conexión
hacia GitHub. Un runner hospedado no tendrá ruta a OpenBao ni al clúster.

El contrato de sincronización exige:

- identificador lógico, ruta y versión de OpenBao;
- repositorio y, opcionalmente, environment destino fijados en la allowlist;
- una única versión activa; una versión histórica no puede republicarse;
- allowlist explícita de nombres de secretos CI;
- lectura interactiva o identidad local de corta duración;
- envío por entrada estándar a `gh secret set`;
- ninguna variable, argumento, fichero temporal o salida con el valor;
- registro de actor, versión, destino, instante y resultado sin valor ni hash
  susceptible de facilitar ataques;
- revocación en GitHub cuando se retire el secreto de OpenBao.

La misma operación admite `delete` para retirar la réplica GitHub sin leer el
valor. Cambiar el destino requiere un cambio revisado de la allowlist.
Antes de sincronizar, se verifica que la versión allowlisted sea la versión
actual de OpenBao y que no esté eliminada o destruida. El workflow consumidor
debe leer también la variable no secreta `<NOMBRE>_OPENBAO_VERSION`; la CI
rechaza cualquier job consumidor que no tenga una condición fail-closed exacta
contra la versión activa fijada en la allowlist.

GitHub Secrets no alojará secretos runtime, credenciales de dispositivos,
claves privadas SOPS, material de unseal, contexto del acuario ni backups.

## 4. Trazabilidad

La evidencia no sensible de una sincronización tendrá:

- `operation_id`;
- actor y método de autenticación local;
- decisión de autorización;
- `secret_id` y versión OpenBao;
- owner, repositorio, aplicación de GitHub y environment;
- fecha de inicio y final;
- resultado y error redactado;
- `correlation_id` y `causation_id`.

La auditoría funcional y el audit device de OpenBao son fuentes distintas. Los
logs técnicos ayudan al diagnóstico, pero no reemplazan ninguna de ellas.

## 5. Rotación y replay

Una rotación crea una versión nueva, actualiza consumidores y después revoca la
anterior. Reintentar la sincronización de la misma versión es idempotente.
Reproducir evidencia no vuelve a leer ni publicar el valor.

La rotación de un secreto CI no despliega aplicaciones. Si afecta a un
artefacto o release, el workflow y el digest resultante conservarán su propia
trazabilidad.
