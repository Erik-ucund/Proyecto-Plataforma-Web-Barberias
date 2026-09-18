
--  NAVALIA - Sistema SaaS de Gestión para Barberías
--  Base de Datos Multi-Tenant (PostgreSQL)
--  Versión: 1.0  |  Fecha: 2026-09-18
--  Autor: Erik Santiago Ortiz Castañeda


-- ─── EXTENSIONES 
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
-- Habilita el uso de "=" para UUIDs dentro de índices GiST
CREATE EXTENSION IF NOT EXISTS "btree_gist"; 

-- ─── TIPOS PERSONALIZADOS 
-- Creamos el tipo de rango para horas que PostgreSQL no trae por defecto
CREATE TYPE timerange AS RANGE (
    subtype = time
);

-- ============================================================
--  1. TABLA PRINCIPAL: BARBERÍA (TENANT)
-- ============================================================
CREATE TABLE barberia (
    id_barberia     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          VARCHAR(120) NOT NULL,
    nit             VARCHAR(30)  UNIQUE,
    subdominio      VARCHAR(60)  UNIQUE NOT NULL,
    direccion       VARCHAR(255),
    logo_url        VARCHAR(500),
    horario_apertura TIME,
    horario_cierre   TIME,
    plan_suscripcion VARCHAR(30) DEFAULT 'basico'
                     CHECK (plan_suscripcion IN ('basico','premium','enterprise')),
    activo          BOOLEAN DEFAULT TRUE,
    creado_en       TIMESTAMPTZ DEFAULT NOW(),
    actualizado_en  TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE barberia IS 'Unidad de negocio multi-tenant. Cada registro = un tenant (RF-MT01, RF-MT02).';

-- ============================================================
--  2. TABLA: USUARIO
-- ============================================================
CREATE TABLE usuario (
    id_usuario      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia) ON DELETE CASCADE,
    nombre          VARCHAR(80)  NOT NULL,
    apellido        VARCHAR(80)  NOT NULL,
    correo          VARCHAR(150) NOT NULL,
    password_hash   TEXT         NOT NULL,
    telefono        VARCHAR(20),
    rol             VARCHAR(20)  NOT NULL CHECK (rol IN ('cliente','barbero','administrador')),
    foto_perfil_url VARCHAR(500),
    activo          BOOLEAN DEFAULT TRUE,
    intentos_fallidos INT DEFAULT 0,
    bloqueado_hasta TIMESTAMPTZ,
    ultimo_login    TIMESTAMPTZ,
    creado_en       TIMESTAMPTZ DEFAULT NOW(),
    actualizado_en  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (id_barberia, correo)
);

COMMENT ON TABLE usuario IS 'Clientes, barberos y administradores. Aislados por id_barberia (RF-MT05).';

-- ============================================================
--  3. TABLA: SERVICIO
-- ============================================================
CREATE TABLE servicio (
    id_servicio     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia) ON DELETE CASCADE,
    nombre          VARCHAR(120) NOT NULL,
    descripcion     TEXT,
    precio          NUMERIC(10,2) NOT NULL CHECK (precio >= 0),
    duracion_minutos INT NOT NULL CHECK (duracion_minutos > 0),
    tipo            VARCHAR(60),
    activo          BOOLEAN DEFAULT TRUE,
    creado_en       TIMESTAMPTZ DEFAULT NOW(),
    actualizado_en  TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE servicio IS 'Catálogo por tenant. Servicios inactivos no se muestran al cliente (RF-AD03).';

-- ============================================================
--  4. TABLA: CITA
-- ============================================================
CREATE TABLE cita (
    id_cita         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia) ON DELETE CASCADE,
    id_cliente      UUID NOT NULL REFERENCES usuario(id_usuario),
    id_barbero      UUID NOT NULL REFERENCES usuario(id_usuario),
    id_servicio     UUID NOT NULL REFERENCES servicio(id_servicio),
    fecha           DATE         NOT NULL,
    hora_inicio     TIME         NOT NULL,
    hora_fin        TIME         NOT NULL,
    estado          VARCHAR(20)  NOT NULL DEFAULT 'pendiente'
                    CHECK (estado IN ('pendiente','confirmada','rechazada','completada','cancelada')),
    motivo_rechazo  TEXT,
    motivo_cancelacion TEXT,
    auto_confirmar_en TIMESTAMPTZ,
    creado_en       TIMESTAMPTZ DEFAULT NOW(),
    actualizado_en  TIMESTAMPTZ DEFAULT NOW(),

    -- Evitar doble reserva del mismo barbero (RF-CI11)
    EXCLUDE USING gist (
        id_barbero  WITH =,
        id_barberia WITH =,
        daterange(fecha, fecha, '[]') WITH &&,
        timerange(hora_inicio, hora_fin, '()') WITH &&
    ) WHERE (estado IN ('pendiente','confirmada'))
);

COMMENT ON TABLE cita IS 'Entidad central. Incluye restricción de solapamiento por barbero (RF-CI11).';

CREATE INDEX idx_cita_barberia  ON cita(id_barberia);
CREATE INDEX idx_cita_barbero   ON cita(id_barbero, fecha);
CREATE INDEX idx_cita_cliente   ON cita(id_cliente);
CREATE INDEX idx_cita_estado    ON cita(estado);

-- ============================================================
--  5. TABLA: CALIFICACION
-- ============================================================
CREATE TABLE calificacion (
    id_calificacion UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cita         UUID NOT NULL UNIQUE REFERENCES cita(id_cita) ON DELETE CASCADE,
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia),
    puntaje         SMALLINT NOT NULL CHECK (puntaje BETWEEN 1 AND 5),
    comentario      VARCHAR(500),
    respuesta_barbero TEXT,
    creado_en       TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
--  6. TABLA: DIAGNOSTICO_FACIAL
-- ============================================================
CREATE TABLE diagnostico_facial (
    id_diagnostico  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_cita         UUID NOT NULL UNIQUE REFERENCES cita(id_cita) ON DELETE CASCADE,
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia),
    id_cliente      UUID NOT NULL REFERENCES usuario(id_usuario),
    forma_facial    VARCHAR(30) CHECK (forma_facial IN ('ovalado','redondo','cuadrado','triangular','oblongo')),
    confianza_pct   NUMERIC(5,2),
    foto_url        VARCHAR(500),
    recomendacion_ia TEXT,
    corte_realizado VARCHAR(120),
    ajuste_barbero  TEXT,
    consentimiento_otorgado BOOLEAN NOT NULL DEFAULT FALSE,
    consentimiento_fecha    TIMESTAMPTZ,
    guardado_en_perfil BOOLEAN DEFAULT FALSE,
    creado_en       TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
--  7. TABLA: NOTIFICACION
-- ============================================================
CREATE TABLE notificacion (
    id_notificacion UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia),
    id_cita         UUID REFERENCES cita(id_cita) ON DELETE SET NULL,
    id_usuario      UUID NOT NULL REFERENCES usuario(id_usuario),
    tipo            VARCHAR(40) NOT NULL CHECK (tipo IN ('confirmacion_cita','rechazo_cita','recordatorio_24h','recordatorio_2h','cancelacion_barbero','nueva_solicitud')),
    canal           VARCHAR(20) NOT NULL DEFAULT 'correo' CHECK (canal IN ('correo','whatsapp','push')),
    estado          VARCHAR(20) NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('enviada','fallida','pendiente','leida')),
    intentos        SMALLINT DEFAULT 0,
    enviada_en      TIMESTAMPTZ,
    creado_en       TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
--  8. TABLA: HORARIO_BLOQUEADO
-- ============================================================
CREATE TABLE horario_bloqueado (
    id_bloqueo      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia),
    id_barbero      UUID NOT NULL REFERENCES usuario(id_usuario),
    fecha           DATE NOT NULL,
    hora_inicio     TIME NOT NULL,
    hora_fin        TIME NOT NULL,
    motivo          VARCHAR(255),
    creado_en       TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
--  9. TABLA: PREFERENCIA_CORTE
-- ============================================================
CREATE TABLE preferencia_corte (
    id_preferencia  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia     UUID NOT NULL REFERENCES barberia(id_barberia),
    id_cliente      UUID NOT NULL REFERENCES usuario(id_usuario),
    forma_facial    VARCHAR(30),
    cortes_sugeridos TEXT[],
    actualizado_en  TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (id_barberia, id_cliente)
);

-- ============================================================
--  10. TABLA: CONSENTIMIENTO_IMAGEN
-- ============================================================
CREATE TABLE consentimiento_imagen (
    id_consentimiento UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    id_barberia       UUID NOT NULL REFERENCES barberia(id_barberia),
    id_cliente        UUID NOT NULL REFERENCES usuario(id_usuario),
    otorgado          BOOLEAN NOT NULL,
    fecha_hora        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_cliente        VARCHAR(45),
    version_politica  VARCHAR(20) DEFAULT '1.0'
);

-- ============================================================
--  FUNCIÓN + TRIGGER: actualizado_en automático
-- ============================================================
CREATE OR REPLACE FUNCTION fn_actualizar_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.actualizado_en = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_barberia_ts BEFORE UPDATE ON barberia FOR EACH ROW EXECUTE FUNCTION fn_actualizar_timestamp();
CREATE TRIGGER trg_usuario_ts BEFORE UPDATE ON usuario FOR EACH ROW EXECUTE FUNCTION fn_actualizar_timestamp();
CREATE TRIGGER trg_servicio_ts BEFORE UPDATE ON servicio FOR EACH ROW EXECUTE FUNCTION fn_actualizar_timestamp();
CREATE TRIGGER trg_cita_ts BEFORE UPDATE ON cita FOR EACH ROW EXECUTE FUNCTION fn_actualizar_timestamp();

-- ============================================================
--  FUNCIÓN: Bloqueo automático por intentos fallidos (RNF-AU05)
-- ============================================================
CREATE OR REPLACE FUNCTION fn_bloquear_usuario()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.intentos_fallidos >= 5 THEN
        NEW.bloqueado_hasta = NOW() + INTERVAL '30 minutes';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_bloqueo_usuario
    BEFORE UPDATE OF intentos_fallidos ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_bloquear_usuario();

-- ============================================================
--  DATOS DE PRUEBA: Tenant 001 — Dinastía BarberStudio
-- ============================================================

INSERT INTO barberia (id_barberia, nombre, nit, subdominio, direccion, horario_apertura, horario_cierre, plan_suscripcion)
VALUES (
    '00000000-0000-0000-0000-000000000001', 'Dinastía BarberStudio', '900123456-7', 'dinastia', 
    'Calle 5 #8-20, Ubaté, Cundinamarca', '08:00', '19:00', 'premium'
);

INSERT INTO usuario (id_barberia, nombre, apellido, correo, password_hash, rol)
VALUES (
    '00000000-0000-0000-0000-000000000001', 'Erik', 'Ortiz', 'admin@dinastia.navalia.co',
    '$2b$12$PlaceholderHashAdmin000000000000000000000000000000000', 'administrador'
);

INSERT INTO usuario (id_barberia, nombre, apellido, correo, password_hash, rol)
VALUES (
    '00000000-0000-0000-0000-000000000001', 'Carlos', 'Morales', 'carlos@dinastia.navalia.co',
    '$2b$12$PlaceholderHashBarbero0000000000000000000000000000000', 'barbero'
);

INSERT INTO usuario (id_barberia, nombre, apellido, correo, password_hash, telefono, rol)
VALUES (
    '00000000-0000-0000-0000-000000000001', 'Juan', 'Pérez', 'juan@correo.com',
    '$2b$12$PlaceholderHashCliente0000000000000000000000000000000', '3101234567', 'cliente'
);

INSERT INTO servicio (id_barberia, nombre, descripcion, precio, duracion_minutos, tipo)
VALUES
    ('00000000-0000-0000-0000-000000000001', 'Corte Clásico', 'Corte tradicional con tijeras y máquina', 25000, 30, 'corte'),
    ('00000000-0000-0000-0000-000000000001', 'Arreglo de Barba', 'Perfilado y arreglo con navaja', 15000, 20, 'barba'),
    ('00000000-0000-0000-0000-000000000001', 'Corte + Barba', 'Servicio completo corte y barba', 35000, 45, 'combo');

	