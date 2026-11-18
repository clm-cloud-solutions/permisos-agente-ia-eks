"""Función de rotación de Secrets Manager para el secreto de orders-api.

Estrategia de un solo usuario, como la plantilla de AWS para PostgreSQL: el rol
(orders_app) cambia su propia contraseña. Secrets Manager llama a los cuatro
pasos en orden, con el mismo ClientRequestToken (el ID de la versión nueva):

  createSecret  una contraseña aleatoria nueva, guardada como AWSPENDING
  setSecret     ALTER ROLE ... PASSWORD, con la sesión de AWSCURRENT
  testSecret    login con AWSPENDING
  finishSecret  AWSCURRENT pasa a la versión nueva (la vieja queda como
                AWSPREVIOUS) y, como política de este laboratorio, se cierran
                las sesiones anteriores del rol: nadie sigue trabajando con una
                contraseña retirada

Valor del secreto: {"username": "orders_app", "password": "..."}. La base sale
del entorno (DB_HOST, DB_PORT, DB_NAME). TLS se verifica contra el bundle de la
CA de RDS empaquetado junto a este archivo (rds-ca.pem). Las contraseñas nunca
se escriben en el log. La empaqueta scripts/aws-up.sh y la despliega
aws/lab.yaml.
"""
import json
import os
import secrets
import ssl
import string

import boto3
import pg8000.native
from pg8000.exceptions import DatabaseError

sm = boto3.client("secretsmanager")
TLS = ssl.create_default_context(cafile=os.path.join(os.path.dirname(__file__), "rds-ca.pem"))
ALPHABET = string.ascii_letters + string.digits


def handler(event, context):
    arn, token, step = event["SecretId"], event["ClientRequestToken"], event["Step"]
    meta = sm.describe_secret(SecretId=arn)
    if not meta.get("RotationEnabled"):
        raise ValueError(f"rotation is not enabled for {arn}")
    stages = meta["VersionIdsToStages"]
    if token not in stages:
        raise ValueError(f"version {token} has no stage in {arn}")
    if "AWSCURRENT" in stages[token]:
        print(f"{step}: version {token} is already AWSCURRENT")
        return
    if "AWSPENDING" not in stages[token]:
        raise ValueError(f"version {token} is not AWSPENDING in {arn}")
    STEPS[step](arn, token)


def get(arn, stage, token=None):
    kwargs = {"VersionId": token} if token else {}
    return json.loads(sm.get_secret_value(SecretId=arn, VersionStage=stage, **kwargs)["SecretString"])


def connect(secret):
    return pg8000.native.Connection(
        secret["username"], password=secret["password"], host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")), database=os.environ.get("DB_NAME", "shop"),
        ssl_context=TLS, timeout=5, application_name="orders-db-rotation")


def create_secret(arn, token):
    current = get(arn, "AWSCURRENT")
    try:
        get(arn, "AWSPENDING", token)
        print(f"createSecret: {token} already holds a value")
    except sm.exceptions.ResourceNotFoundException:
        pending = dict(current, password="".join(secrets.choice(ALPHABET) for _ in range(32)))
        sm.put_secret_value(SecretId=arn, ClientRequestToken=token,
                            SecretString=json.dumps(pending), VersionStages=["AWSPENDING"])
        print(f"createSecret: new version {token} stored as AWSPENDING")


def set_secret(arn, token):
    pending = get(arn, "AWSPENDING", token)
    try:  # un paso reintentado: puede que el rol ya la tenga
        connect(pending).close()
        print("setSecret: the role already logs in with AWSPENDING")
        return
    except DatabaseError:
        pass
    current = get(arn, "AWSCURRENT")
    conn = connect(current)
    try:
        # ALTER ROLE no admite parámetros: el valor va como literal escapado.
        conn.run(f"ALTER ROLE {pg8000.native.identifier(current['username'])} "
                 f"PASSWORD {pg8000.native.literal(pending['password'])}")
    finally:
        conn.close()
    print(f"setSecret: {current['username']} now has the AWSPENDING password")


def test_secret(arn, token):
    connect(get(arn, "AWSPENDING", token)).close()
    print("testSecret: AWSPENDING logs in")


def finish_secret(arn, token):
    # La versión nueva se lee por su ID antes de mover la etiqueta: justo después
    # del cambio, AWSCURRENT puede devolver todavía el valor viejo un instante.
    new = get(arn, "AWSPENDING", token)
    stages = sm.describe_secret(SecretId=arn)["VersionIdsToStages"]
    old = next(v for v, s in stages.items() if "AWSCURRENT" in s)
    sm.update_secret_version_stage(SecretId=arn, VersionStage="AWSCURRENT",
                                   MoveToVersionId=token, RemoveFromVersionId=old)
    conn = connect(new)
    try:
        ended = conn.run("SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity "
                         "WHERE usename = :u AND pid <> pg_backend_pid()", u=new["username"])[0][0]
    finally:
        conn.close()
    print(f"finishSecret: {token} is AWSCURRENT (was {old}); "
          f"ended {ended} older session(s) of {new['username']}")


STEPS = {"createSecret": create_secret, "setSecret": set_secret,
         "testSecret": test_secret, "finishSecret": finish_secret}
