CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. medicamentos
CREATE TABLE IF NOT EXISTS medicamentos (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255) NOT NULL,
    tipo VARCHAR(20) CHECK (tipo IN ('Común', 'Controlado')),
    descripcion TEXT,
    precio DECIMAL(10,2) DEFAULT 0.00,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. lotes
CREATE TABLE IF NOT EXISTS lotes (
    id SERIAL PRIMARY KEY,
    medicamento_id INT NOT NULL REFERENCES medicamentos(id) ON DELETE CASCADE,
    lote_numero VARCHAR(100) UNIQUE NOT NULL,
    fecha_vencimiento DATE NOT NULL,
    stock INT NOT NULL CHECK (stock >= 0),
    fecha_ingreso DATE DEFAULT CURRENT_DATE
);

-- 4. medicos
CREATE TABLE medicos (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255) NOT NULL,
    especialidad VARCHAR(100),
    cmp VARCHAR(20) UNIQUE
);


-- 4. pacientes (sin encriptación, campos TEXT)
CREATE TABLE IF NOT EXISTS pacientes (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255),          -- Visible
    dni VARCHAR(8) UNIQUE,        -- Visible
    direccion BYTEA,              -- Encriptado
    telefono BYTEA,               -- Encriptado
    alergias BYTEA,               -- Encriptado
    historial_medico BYTEA,       -- Encriptado
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- 5. recetas (sin encriptación, campos TEXT)
CREATE TABLE IF NOT EXISTS recetas (
    id SERIAL PRIMARY KEY,
    paciente_id INT REFERENCES pacientes(id),
    medico_id INT REFERENCES medicos(id),
    fecha_emision DATE DEFAULT CURRENT_DATE,
    fecha_vencimiento DATE,
    diagnostico BYTEA,
    tratamiento BYTEA,
    instrucciones BYTEA,
    observaciones BYTEA,
    estado VARCHAR(20) DEFAULT 'Válida' CHECK (estado IN ('Válida', 'Usada', 'Vencida'))
);

-- 6. ventas
CREATE TABLE ventas (
    id SERIAL PRIMARY KEY,
    receta_id INT REFERENCES recetas(id),
    fecha_venta TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    usuario VARCHAR(50) NOT NULL
);

-- 7. detalles_venta
CREATE TABLE detalles_venta (
    id SERIAL PRIMARY KEY,
    venta_id INT REFERENCES ventas(id),
    lote_id INT REFERENCES lotes(id),
    medicamento_id INT REFERENCES medicamentos(id),
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(10,2)
);

-- 8. auditoria_controlados - Requisito 3
CREATE TABLE IF NOT EXISTS auditoria_controlados (
    id SERIAL PRIMARY KEY,
    venta_id INT REFERENCES ventas(id),
    medicamento_controlado_id INT REFERENCES medicamentos(id),
    paciente_id INT REFERENCES pacientes(id),
    medico_id INT REFERENCES medicos(id),
    cantidad_dispensada INT NOT NULL,
    usuario_que_dispenso VARCHAR(50) NOT NULL,
    fecha_dispensacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    numero_receta VARCHAR(100),
    motivo_consulta TEXT
);

-- 9. alertas_vencimiento
CREATE TABLE IF NOT EXISTS alertas_vencimiento (
    id SERIAL PRIMARY KEY,
    lote_id INT REFERENCES lotes(id),
    mensaje TEXT,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    procesado BOOLEAN DEFAULT FALSE
);
---10 Requisito 5
CREATE TABLE usuarios (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE,
    rol VARCHAR(20) CHECK (rol IN ('admin', 'farmaceutico', 'invitado')),
    clave_desbloqueo TEXT  -- puede estar vacía si no deben ver datos cifrados
);
