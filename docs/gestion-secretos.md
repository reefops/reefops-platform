# Gestión de secretos

## 1. Autoridad y alcance

OpenBao es la autoridad local para secretos runtime y credenciales de
automatización. Pertenece a plataforma, no a ningún dominio de negocio.

Se distinguen cuatro clases:

| Clase | Autoridad | Entrega |
|---|---|---|
| Runtime de workloads | OpenBao local | Identidad Kubernetes; volumen en memoria o Secret Kubernetes cuando el consumidor lo exija |
| Bootstrap de OpenBao/Flux | Custodia offline | SOPS + `age` solo cuando deba declararse cifrado |
| CI de GitHub | OpenBao local | Réplica revocable en GitHub Secrets |
| Datos, medios y backups | Almacén local correspondiente | Nunca GitHub Secrets |

Los servicios de dominio no importarán un SDK de OpenBao ni conocerán dónde se
custodia un secreto. La plataforma lo montará como archivo o lo entregará al
adaptador técnico correspondiente.

External Secrets Operator —ESO— será el adaptador declarativo para operadores
que exijan un Secret Kubernetes. ESO no se convierte en autoridad ni justifica
sincronizar rutas completas: cada `ExternalSecret` declarará claves concretas,
propietario y política de ciclo de vida.

La NetworkPolicy solo permite clientes desde namespaces autorizados
explícitamente con `reefops.io/openbao-access=true`; pertenecer a ReefOps no
concede acceso lateral al gestor. ESO es la excepción más estrecha: combina
namespace y entorno exactos con el label del pod controlador, sin conceder la
capacidad a todo `reefops-secret-delivery`.

La deploy key de lectura de `reefops-gitops` es una credencial de bootstrap:
se genera localmente, se registra como read-only y se instala en `flux-system`.
Puede regenerarse y revocarse sin restaurar datos de OpenBao.

## 2. OpenBao local

OpenBao se desplegará mediante GitOps en el repositorio `reefops-platform`.
Usará almacenamiento persistente y audit device separado. En el Mac Mini
inicial se ejecutará como instancia standalone; esto no se presentará como alta
disponibilidad.

El chart oficial se consume desde GHCR como artefacto OCI fijado por digest,
igual que los charts de cert-manager y ESO. La imagen de OpenBao también se
fija por digest. `task validate` obtiene el chart declarado, compara su digest
y renderiza las configuraciones activa y de recuperación antes de permitir una
promoción.

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

El audit device `file/` se declara en el HCL del servidor y escribe en el PVC
dedicado. OpenBao 2.6 impide crearlo mediante API para que una credencial
administrativa no pueda redirigir auditoría a destinos arbitrarios. Los scripts
solo verifican su presencia; no se habilita
`unsafe_allow_api_audit_creation`.
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

El chart copia la configuración renderizada a un fichero de trabajo dentro del
pod. Por ello, una reconciliación GitOps del ConfigMap no basta para activar un
cambio HCL en el proceso existente. La operación local de recarga compara la
configuración versionada y la activa en el fichero de trabajo antes de enviar
`SIGHUP`; registra hashes, actor, autorización, correlación, resultado y
comprueba la confirmación de recarga emitida por OpenBao y que el proceso
continúa preparado. La señal se envía en cada intento, aunque los ficheros ya
coincidan, para que un fallo parcial sea reintentable. No modifica el estado
deseado ni acepta configuración fuera del ConfigMap reconciliado.
La evidencia incluye revisión Git local, contexto, UID y `resourceVersion` del
ConfigMap y UID del pod. Un lock local serializa operadores en este host; la
comparación del `resourceVersion` evita activar una revisión que cambió durante
la operación.

Dependencias y orden:

1. namespace, almacenamiento y políticas de red;
2. cert-manager y sus CRD;
3. CA local y certificado TLS de OpenBao;
4. OpenBao;
5. inicialización y unseal mediante procedimiento local;
6. auth de Kubernetes y políticas de mínimo privilegio;
7. integración de entrega a workloads;
8. aplicaciones que consumen secretos.

## 3. Integración ESO

La primera integración se instala en `reefops-secret-delivery`, un namespace
sin claves privadas de OpenBao ni de otros consumidores, y contiene:

- chart OCI e imagen fijados por digest;
- controlador scoped bajo Pod Security `restricted`;
- webhook y cert-controller desactivados para evitar RBAC global innecesario;
- `SecretStore` namespaced con backend KV v2 `ci/`;
- CA pública fijada por la composición privada en el ConfigMap
  `openbao-ca-bundle`, sin copiar `tls.key` ni omitir verificación;
- ServiceAccount `external-secrets-openbao`, dedicada a autenticación
  Kubernetes y sin token montado permanentemente;
- rol `reefops-external-secrets` y política OpenBao limitados a
  `ci/eso-smoke-test`;
- `ExternalSecret` y Secret destino exclusivamente sintéticos.

El controlador de ESO conserva su ServiceAccount operativo para hablar con la
API Kubernetes. No se reutiliza como identidad OpenBao: solicita mediante
TokenRequest un token breve para `external-secrets-openbao` y lo canjea por un
token OpenBao con TTL limitado.

No se crea inicialmente un `ClusterSecretStore`. Cada namespace consumidor
recibirá una instancia ESO scoped o un mecanismo equivalente, CA pública,
ServiceAccount y política propios. Una identidad de un operador de datos no
podrá leer secretos de dominios, inteligencia o identidad.

SeaweedFS será el primer consumidor real de ese patrón. `reefops-data` tendrá
su propio `SecretStore`, ServiceAccount y rol OpenBao, limitados a
`platform/seaweedfs/s3`. ESO compondrá el único fichero
`seaweedfs_s3_config` que requiere el chart. El bootstrap será create-once:
encontrar la ruta existente no imprime ni rota credenciales, y su ausencia
genera valores localmente antes de escribirlos en OpenBao.

La prueba de aceptación:

1. verifica que OpenBao está inicializado, no sellado y auditando;
2. autentica ESO mediante Kubernetes, sin credencial estática;
3. espera `SecretStore` y `ExternalSecret` preparados;
4. compara la clave sintética sin imprimirla;
5. rota el valor sintético y comprueba el refresco;
6. revoca temporalmente el acceso y comprueba fallo cerrado sin sustituir el
   valor por un default;
7. restaura la política y el valor sintético original;
8. registra operación, actor, revisión, `environment_id`, correlación,
   causación y resultado, pero nunca el valor.

El orden operativo limpio es:

1. validar y publicar el commit de plataforma;
2. ejecutar `openbao-configure` contra el OpenBao activo;
3. promover ese SHA completo mediante PR en `reefops-gitops`;
4. esperar todas las reconciliaciones Flux;
5. ejecutar `openbao-verify-eso`.

La prueba usa el token raíz original solo durante la ceremonia interactiva; no
genera nuevas claves ni lo conserva. Su evidencia queda en
`~/.local/state/reefops/eso-openbao/operations.jsonl`.
La revisión local debe coincidir exactamente con
`reefops-external-secrets-openbao.status.lastAppliedRevision`; una diferencia
falla antes de capturar o mutar la política.

La verificación crea su propio port-forward al Service activo, fija SNI y CA,
exige el contexto `docker-desktop`, comprueba la etiqueta
`environment=development` y compara el `cluster_id` observado por el endpoint
con el del pod activo. No acepta una dirección OpenBao aportada por el
operador, por lo que no puede reutilizar accidentalmente el endpoint de
recovery.

Un lock local serializa el ensayo. Antes de mutar captura política y valor
sintético; el trap intenta restaurarlos y un fallo de restauración convierte la
operación en error. La evidencia enlaza revisión Flux aplicada, UID y
generación de `SecretStore`/`ExternalSecret`, `cluster_id` y aumento de entradas
de login/lectura en el audit device. La revocación escribe una nueva versión
sintética y verifica que no llega al Secret destino antes de restaurar.

Las regresiones observadas durante la primera aceptación quedan cubiertas:

- ambos wrappers usan exactamente el JSONPath de
  `reefops.io/environment`, sin doble escape;
- `task validate` ejecuta `bash -n` sobre todos los scripts y tests;
- la captura y la restauración consumen el campo `policy` emitido por
  `bao policy read -format=json`;
- todo fallo informa de la fase y enlaza la evidencia no sensible.

Un fallo anterior a la captura no muta estado. Después de capturarlo, el trap
restaura política y valor; si no puede demostrar la restauración, devuelve un
error distinto y la integración no se considera aceptada.

La indisponibilidad o sellado de OpenBao impide nuevos refrescos. ESO podrá
conservar temporalmente el último Secret materializado según la política
declarada, por lo que cada consumidor deberá definir si puede continuar, debe
degradarse o ha de detenerse. Esta caché Kubernetes no sustituye backup,
rotación ni autoridad.

La promoción se realiza en dos fases. Primero se publica el catálogo de
plataforma y se ejecuta `openbao-configure` contra la autoridad activa para
crear rol, política y valor sintético. Solo después se promocionan las
Kustomizations ESO en GitOps. En un bootstrap nuevo, omitir la ceremonia deja
el `SecretStore` en `NotReady` y no desbloquea consumidores; `dependsOn` no se
interpreta como prueba de que OpenBao esté inicializado o configurado.

`openbao-configure` no acepta un endpoint arbitrario: el wrapper fija contexto,
namespace, port-forward, CA y SNI del Service activo, compara su `cluster_id`
con el observado dentro del pod y entrega ese identificador al registro de la
operación. El token raíz se recibe únicamente por entorno y se retira al
terminar.

## 4. Salud y recuperación de OpenBao

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
- verificación no destructiva de cada snapshot mediante digest, descifrado
  efímero, estructura y checksums internos del archivo Raft, sin aplicar una
  restauración;
- backup de CA y metadatos de certificados conforme al runbook de plataforma;
- custodia offline de recovery/unseal material;
- restauración ensayada y documentada;
- rotación posterior de credenciales potencialmente expuestas;
- evidencia de actor, autorización, backup, versión y resultado.

La verificación elimina el snapshot en claro al terminar y conserva únicamente
evidencia no sensible. Demuestra legibilidad e integridad del artefacto, pero no
sustituye al ensayo periódico de restauración aislada.
Cada snapshot se acompaña de un manifiesto cifrado con `age` que contiene
digest, versión productora, cluster ID y fecha. Su SHA-256 se custodia en la
evidencia de backup y se exige independientemente para impedir sustituciones.
El restore falla de forma segura si el
manifiesto no corresponde al artefacto o la versión ejecutora no coincide
exactamente con la productora; ampliar la matriz de compatibilidad exige una
decisión versionada y ensayada.

La restauración exige un artefacto de aprobación previo, de un solo uso,
acotado por digest, modo, cluster, actor y caducidad, además de una confirmación
ligada al digest. Durante el bootstrap local ese artefacto representa la
aprobación explícita del operador de confianza, no una autorización
independiente. Antes de permitir restores delegados deberá emitirlo y
verificarlo el sistema gestionado de autorización. El backup preventivo y la
verificación posterior conservan la correlación y declaran la operación de
restore como causa inmediata.

Los JSONL locales son evidencia operativa mutable, no auditoría funcional
inmutable. Se protegen con permisos mínimos y deberán copiarse al almacén de
evidencias con retención e integridad cuando ese componente esté desplegado.

### Ensayo aislado de recuperación

El ensayo periódico no reutiliza el namespace, Service, certificados ni PVC
del OpenBao activo. Se despliega mediante una raíz IaC opt-in en
`reefops-openbao-recovery`, con nombre DNS y CA propios, sin Ingress y con
NetworkPolicy de denegación por defecto. La composición privada habilita esa
raíz temporalmente mediante una Kustomization independiente; no se incorpora
al root normal de plataforma.

Raft sí exige reutilizar el `node_id` contenido en el snapshot para que el nodo
restaurado pueda reconocerse como miembro y elegir líder. En el caso actual es
`reefops-local-0`. Compartir ese identificador lógico no conecta los clústeres:
el aislamiento efectivo lo aportan namespace, endpoint, PKI, red y volúmenes
distintos. El preflight y el restore verifican el valor esperado antes de actuar.

La configuración declarativa de componentes persistidos también debe ser
semánticamente idéntica a la del snapshot. En particular, nombre, path, tipo,
descripción y opciones del audit device deben coincidir; OpenBao rechaza
modificarlos durante el post-unseal. El entorno aislado conserva por ello la
descripción funcional original aunque escriba en un PVC de audit diferente.

La secuencia es:

1. reconciliar el entorno aislado y comprobar que nace sin inicializar;
2. inicializarlo con material temporal, sin imprimirlo ni versionarlo;
3. descifrar y validar el snapshot y su manifiesto en almacenamiento efímero;
4. aplicar el restore forzado únicamente al endpoint aislado;
5. desechar el material temporal y realizar unseal con el material original;
6. comprobar identidad del clúster restaurado, audit y mounts; la autenticación
   Kubernetes se prueba separadamente en la autoridad activa;
7. registrar RPO/RTO, versiones, digest, actor, correlación y resultado;
8. retirar la Kustomization mediante GitOps y confirmar la eliminación de
   workloads, PVC y referencias PV temporales.

El cierre no se redacta manualmente. `openbao-verify-recovery` comprueba con una
identidad restaurada el contrato audit runtime, mounts, Raft, revisión GitOps y
salud inalterada del activo. `openbao-recovery-evidence-seal` cifra por
streaming el audit y un bundle con los registros canónicos de restore y
verificación, sus hashes y el inventario bijectivo de PVC/PV. El sellado usa
temporales y renames atómicos y puede reanudar un resultado incierto.
Finalmente, `openbao-recovery-close` exige esa verificación concreta, comprueba
los digest, descifra y valida el bundle, enlaza causalmente el restore y
calcula:

- RPO observado: inicio del drill menos creación del snapshot;
- RTO observado: verificación satisfactoria menos inicio del drill.

El cierre añade bajo lock una única operación por `closure_operation_id` y
mueve atómicamente `current.json` a `attempts/<drill_id>.json` con fase
`closed-success-eligible-for-cleanup`. Si el proceso cae después del append, el
retry detecta la misma operación y completa únicamente el archivo del estado.
El JSONL local sigue siendo evidencia operativa mutable; la integridad
portable la aportan los artefactos cifrados y sus digest, no una afirmación
WORM que el filesystem local no puede garantizar.

El script de restore debe recibir y comprobar explícitamente el endpoint y el
cluster ID objetivo. La aprobación indicará el contexto y namespace de
recuperación; nunca será válida para `reefops-secrets`. La eliminación de PVC
del ensayo es intencionada y solo ocurre después de conservar la evidencia.
Un ensayo exitoso demuestra restaurabilidad técnica del snapshot, no alta
disponibilidad del Mac Mini ni custodia suficiente de las claves.

Mientras se construye este ensayo, el comando ejecutable de restore solo acepta
`isolated-recovery`; el restore de la autoridad activa queda deshabilitado y
requerirá un entrypoint separado con su propia allowlist y aprobación. La
aprobación aislada queda ligada también al contexto, UID del clúster
Kubernetes, Service y SNI.

Las tareas `openbao-recovery-preflight` y `openbao-recovery-cleanup-verify`
materializan las guardas anterior y posterior. El preflight falla si el
contexto no es el esperado, la autoridad activa deja de estar preparada, el
target no es el HelmRelease aislado, aparece RBAC cluster-wide o el target ya
está inicializado. También compara el contrato audit completo persistible:
driver, descripción, `file_path`, modo y `log_raw`. La comprobación de limpieza
falla mientras exista cualquier namespace, HelmRelease, StatefulSet, pod, PVC
o PV todavía enlazado al namespace del ensayo.
El cleanup se liga al UID original del clúster, registra revisión GitOps y una
operación idempotente causada por el cierre, y produce un artefacto separado
`cleanup-verified-closed-complete` sin reabrir el archivo 0400 del drill.

`openbao-recovery-init` guarda el resultado sensible de la inicialización
temporal únicamente en `/dev/shm` dentro del pod, con modo `0600`. Las claves
se leen transitoriamente en memoria del proceso local y vuelven por la entrada
estándar de `kubectl exec` para abrir ese target; nunca se imprimen, se pasan
como argumentos ni se escriben en el host. Antes de inicializar se comprueba
que `/dev/shm` sea `tmpfs` y un lock atómico impide ejecuciones concurrentes.
El estado local del drill contiene únicamente identificadores, revisión GitOps
y tiempos.

### Recuperación de la autoridad activa

La restauración destructiva de `reefops-secrets` permanece deliberadamente sin
entrypoint ejecutable. El motor interno de restore no se publica en Taskfile y
mantiene una allowlist constante que solo admite `isolated-recovery`; no puede
convertirse en un motor genérico indicando destino mediante variables.

Habilitar recuperación activa exigirá antes un diseño e implementación
separados para `in-place` y `disaster-recovery`. Como mínimo deberá existir un
fence de mantenimiento verificable, consumidores y emisores detenidos,
snapshot preventivo cifrado y verificado, aprobación de un solo uso ligada a
ambos digest, identidad completa del target, revisión Flux, CA, `node_id`,
actor, caducidad e identificador de cambio o incidente. Un resultado incierto
no será reintentable automáticamente.

Hasta disponer de ese coordinador, la recuperación real se ejecutará adaptando
el procedimiento ensayado bajo revisión humana, no relajando la allowlist ni
reutilizando aprobaciones del entorno aislado. Esta limitación fail-closed es
parte del método limpio y evita presentar una operación destructiva
insuficientemente cercada como automatización terminada.

`openbao-recovery-restore` crea su propio port-forward al Service aislado,
extrae solo la CA pública a un directorio temporal y consume el token raíz
temporal desde memoria. La aprobación no se autoemite: una tarea interactiva
separada exige un challenge ligado al digest y persiste una aprobación acotada
antes de que el ejecutor pueda arrancar. El ejecutor valida esquema, fase,
contexto, UID Kubernetes y revisión GitOps, y usa el mismo lock atómico del
drill. Si el restore se aplica, elimina inmediatamente el material temporal del
pod. Si el resultado es incierto, lo conserva en memoria para permitir
diagnóstico y exige nueva aprobación antes de reintentar.

El procedimiento ejecutable y sus comprobaciones se definen en el
[runbook de recuperación del repositorio de producto](https://github.com/reefops/reefops/blob/main/docs/runbooks/openbao-recuperacion.md).

El StatefulSet activo conservará sus PVC (`Retain`) al eliminarse o escalarse.
El StatefulSet temporal del drill usa `Delete` para que el prune GitOps retire
sus volúmenes después del cierre y del inventario de evidencias; esta diferencia
es deliberada y no se trasladará al activo. OpenBao usará usuario no root,
seccomp `RuntimeDefault`, privilege escalation deshabilitada, capabilities
mínimas y requests/limits explícitos. Un cambio de esos controles deberá
renderizarse y probarse antes de promoverse.

## 5. GitHub Secrets

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

## 6. Trazabilidad

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

## 7. Rotación y replay

Una rotación crea una versión nueva, actualiza consumidores y después revoca la
anterior. Reintentar la sincronización de la misma versión es idempotente.
Reproducir evidencia no vuelve a leer ni publicar el valor.

La rotación de un secreto CI no despliega aplicaciones. Si afecta a un
artefacto o release, el workflow y el digest resultante conservarán su propia
trazabilidad.
