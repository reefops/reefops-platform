# Identidad, autorización y entrada protegida development

## Orden y aislamiento

La promoción instala Linkerd, después ZITADEL y OpenFGA internos, después
ReefOps Authorizer y por último el Gateway protegido. ZITADEL y OpenFGA usan
bases y roles PostgreSQL propios; sus credenciales y la masterkey ZITADEL se
custodian en OpenBao y llegan mediante ESO. OpenFGA permanece exclusivamente
`ClusterIP` y no tiene ruta norte-sur.

Development usa una sola réplica por servicio y no declara HA. La caída de
identidad impide sesiones nuevas; la caída de OpenFGA o Authorizer deniega las
operaciones protegidas. Los dominios internos no dependen del Gateway para
procesar eventos ya autorizados.

## Modelo OpenFGA inicial

El store development contiene un modelo versionado con `user`, `organization`,
`installation` y `aquatic_system`. La pertenencia a organización no concede
por sí sola acceso a todos los recursos: instalación y sistema expresan
relaciones `owner`, `operator` y `viewer`. El primer corte añadirá tuples solo
mediante un adaptador propietario y conservará actor, decisión, modelo,
correlación y causación.

## Entrada local

Los nombres iniciales son `reefops.localhost` e
`identity.reefops.localhost`. El Gateway conserva `ClusterIP` y se alcanza por
port-forward desde el Mac operador. La CA development no se presenta como
confianza pública ni se reutiliza en production. Solo HTTPRoute/GRPCRoute con
namespace seleccionado pueden adjuntarse.

La aceptación prueba token ausente, issuer/audience inválidos, OpenFGA caído,
Authorizer caído, cabeceras falsificadas y acceso directo. Todos fallan cerrados
y ninguno ejecuta el backend sintético. El caso permitido conserva
`request_id`, `correlation_id`, `authz_decision_id` y la versión del modelo.
