-- Crear base de datos

--CREATE DATABASE pharmacy_control;

-- DROP DATABASE IF EXISTS pharmacy_control;
/*
 DROP TABLE IF EXISTS detalles_venta CASCADE;
 DROP TABLE IF EXISTS auditoria_controlados CASCADE;
 DROP TABLE IF EXISTS ventas CASCADE;
 DROP TABLE IF EXISTS recetas CASCADE;
 DROP TABLE IF EXISTS pacientes CASCADE;
 DROP TABLE IF EXISTS medicos CASCADE;
 DROP TABLE IF EXISTS alertas_vencimiento CASCADE;
DROP TABLE IF EXISTS lotes CASCADE;
DROP TABLE IF EXISTS medicamentos CASCADE;
*/
--PREPARACION
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


-- 4. pacientes 
CREATE TABLE IF NOT EXISTS pacientes (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255),          -- Visible
    dni VARCHAR(8) UNIQUE,        -- Visible
    direccion BYTEA,              -- Encriptado
    telefono BYTEA,               -- Encriptado
    alergias BYTEA,               
    historial_medico BYTEA,       
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- 5. recetas 
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

--REQUISITO 3 — Auditoría para medicamentos controlados
-- 8. auditoria_controlados 
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

--REQUISITO 4 — Alertas automáticas (Trigger)
-- 9. alertas_vencimiento
CREATE TABLE IF NOT EXISTS alertas_vencimiento (
    id SERIAL PRIMARY KEY,
    lote_id INT REFERENCES lotes(id),
    mensaje TEXT,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    procesado BOOLEAN DEFAULT FALSE
);

---10. Requisito 5 - USUARIOS Y SEGURIDAD
CREATE TABLE usuarios (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE,
    rol VARCHAR(20) CHECK (rol IN ('admin', 'farmaceutico', 'invitado')),
    clave_desbloqueo TEXT  -- puede estar vacía si no deben ver datos cifrados
);


-- ÍNDICES  PARA REQUISITO 2
CREATE INDEX idx_medicamentos ON medicamentos USING btree(nombre, tipo);
CREATE INDEX idx_lotes ON lotes USING btree(medicamento_id, fecha_vencimiento);
CREATE INDEX idx_fechas_vencimiento ON lotes USING btree(fecha_vencimiento) WHERE stock > 0;
CREATE INDEX idx_recetas ON recetas USING btree(paciente_id, fecha_emision);


---REQUISITO 4: Crear alerta cuando un lote está por vencer
 
CREATE OR REPLACE FUNCTION alerta_vencimiento() RETURNS TRIGGER AS $$
DECLARE
    dias int;
    existe_alerta boolean;
    vencimiento_date date;
BEGIN
    vencimiento_date := NEW.fecha_vencimiento::date;
    dias := (vencimiento_date - CURRENT_DATE);
 -- Crear alerta si faltan 30 días o menos y aún hay stock
    IF (dias <= 30) AND NEW.stock > 0 THEN
	 -- Verificar si YA existe alerta no procesada del mismo lote
        SELECT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE lote_id = NEW.id AND procesado = FALSE
        ) INTO existe_alerta;
     -- Crear alerta si NO existe
        IF NOT existe_alerta THEN
            INSERT INTO alertas_vencimiento (lote_id, mensaje)
            VALUES (
                NEW.id,
                'ALERTA: Lote ' || NEW.lote_numero || ' vence el ' || TO_CHAR(vencimiento_date,'YYYY-MM-DD') || ' - Stock: ' || NEW.stock
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
---
DROP TRIGGER IF EXISTS trigger_alerta_vencimiento ON lotes;
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF fecha_vencimiento, stock ON lotes
FOR EACH ROW EXECUTE FUNCTION alerta_vencimiento();


-- FUNCIÓN TRANSACCIONAL PARA DISPENSAR MEDICAMENTOS (ACID)
/*
Cumple:
-- - ATOMICIDAD: Si algo falla → ROLLBACK automático de PostgreSQL.
-- - CONSISTENCIA: Verifica stock, existencia de lote y receta.
-- - AISLAMIENTO: FOR UPDATE → evita ventas simultáneas del mismo lote.
-- - DURABILIDAD: Cambios quedan guardados de forma permanente.
*/

CREATE OR REPLACE FUNCTION fn_dispensar(
    p_lote_id INT,
    p_cantidad INT,
    p_receta_id INT,
    p_paciente_id INT,
    p_medico_id INT,
    p_usuario VARCHAR
) RETURNS TABLE(resultado TEXT, venta_id INT) AS $$
DECLARE
    v_stock INT;
    v_med_id INT;
    v_precio NUMERIC(10,2);
    v_venta_id INT;
BEGIN
    IF p_cantidad <= 0 THEN
        RETURN QUERY SELECT 'ERROR: cantidad debe ser > 0'::text, NULL::int;
        RETURN;
    END IF;

    -- Bloqueo de fila para evitar condiciones de carrera
    SELECT stock, medicamento_id INTO v_stock, v_med_id
    FROM lotes WHERE id = p_lote_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 'ERROR: lote no encontrado'::text, NULL::int;
        RETURN;
    END IF;
	
 -- Stock insuficiente
    IF v_stock < p_cantidad THEN
        RETURN QUERY SELECT 'ERROR: stock insuficiente'::text, NULL::int;
        RETURN;
    END IF;

      -- Obtener precio del medicamento
    SELECT precio INTO v_precio 
	FROM medicamentos 
	WHERE id = v_med_id;

    -- Restar stock
    UPDATE lotes 
	SET stock = stock - p_cantidad 
	WHERE id = p_lote_id;

    -- Registrar venta
    INSERT INTO ventas (receta_id, usuario) 
	VALUES (p_receta_id, p_usuario) 
	RETURNING id INTO v_venta_id;

     -- Registrar detalle de venta
    INSERT INTO detalles_venta (venta_id, lote_id, medicamento_id, cantidad, precio_unitario)
    VALUES (v_venta_id, p_lote_id, v_med_id, p_cantidad, v_precio);

    -- Si es medicamento controlado, registrar en auditoría
    IF (SELECT tipo FROM medicamentos WHERE id = v_med_id) = 'Controlado' THEN
        INSERT INTO auditoria_controlados (
            venta_id, medicamento_controlado_id, paciente_id,
            medico_id, cantidad_dispensada, usuario_que_dispenso, numero_receta
        ) VALUES (
            v_venta_id, v_med_id, p_paciente_id, p_medico_id, p_cantidad, p_usuario,
            (SELECT id::text FROM recetas WHERE id = p_receta_id)
        );
    END IF;

    RETURN QUERY SELECT 'OK'::text, v_venta_id;
END;
$$ LANGUAGE plpgsql VOLATILE;


--------INSERCION DE DATOS

INSERT INTO medicamentos (nombre, tipo, descripcion, precio) VALUES 
('Aspirina', 'Común', 'Analgésico', 2.50),
('Codeína', 'Controlado', 'Analgésico fuerte', 12.00),
('Ibuprofeno', 'Común', 'Antiinflamatorio', 3.00),
('Amoxicilina', 'Controlado', 'Antibiótico', 8.00)
ON CONFLICT DO NOTHING;


INSERT INTO medicos (nombre, especialidad, cmp) VALUES
('Dr. Juan Pérez', 'Medicina General', 'CMP001'),
('Dra. María López', 'Pediatría', 'CMP002'),
 ('Dr. Carlos', 'General', 'CMP003')
ON CONFLICT DO NOTHING;


-- Pacientes con encriptacion
INSERT INTO pacientes (nombre, dni, direccion, telefono, alergias, historial_medico)
VALUES
( 'Juan Pérez','12345678',
    pgp_sym_encrypt('Calle 123', 'clave_segura'),
    pgp_sym_encrypt('987654321', 'clave_segura'),
    pgp_sym_encrypt('Ninguna', 'clave_segura'),
    pgp_sym_encrypt('Cirugía 2020', 'clave_segura')
),
( 'María López', '87654321',
    pgp_sym_encrypt('Av. Principal', 'clave_segura'),
    pgp_sym_encrypt('999888777', 'clave_segura'),
    pgp_sym_encrypt('Penicilina', 'clave_segura'),
    pgp_sym_encrypt('Diabetes', 'clave_segura')
),
( 'Carlos García', '11223344',
    pgp_sym_encrypt('Plaza Central', 'clave_segura'),
    pgp_sym_encrypt('888777666', 'clave_segura'),
    pgp_sym_encrypt('Sulfa', 'clave_segura'),
    pgp_sym_encrypt('Fractura', 'clave_segura')
)
ON CONFLICT DO NOTHING;



-- RECETAS
INSERT INTO recetas (paciente_id, medico_id, diagnostico, tratamiento, instrucciones, observaciones, fecha_emision, fecha_vencimiento)
VALUES
(1,1,
    pgp_sym_encrypt('Infección respiratoria leve', 'clave_segura'),
    pgp_sym_encrypt('Amoxicilina 500 mg por 7 días', 'clave_segura'),
    pgp_sym_encrypt('Tomar cada 8 horas después de comidas', 'clave_segura'),
    pgp_sym_encrypt('Control en una semana', 'clave_segura'),
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '30 days'
),
( 2, 2,
    pgp_sym_encrypt('Descompensación diabética leve', 'clave_segura'),
    pgp_sym_encrypt('Insulina + dieta controlada', 'clave_segura'),
    pgp_sym_encrypt('Medir glucosa 3 veces al día', 'clave_segura'),
    pgp_sym_encrypt('Evitar azúcares', 'clave_segura'),
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '30 days'
),
(3,3,
    pgp_sym_encrypt('Dolor muscular por caída', 'clave_segura'),
    pgp_sym_encrypt('Ibuprofeno 400 mg por 5 días', 'clave_segura'),
    pgp_sym_encrypt('Reposo y evitar cargar peso', 'clave_segura'),
    pgp_sym_encrypt('Revisión si no mejora', 'clave_segura'),
    CURRENT_DATE,
    CURRENT_DATE + INTERVAL '30 days'
)
RETURNING id; --10,11,12

-- Inserción de lotes
INSERT INTO lotes (medicamento_id, lote_numero, fecha_vencimiento, stock) VALUES
(1, 'LOTE001', CURRENT_DATE + INTERVAL '16 days', 100),
(3, 'LOTE004', CURRENT_DATE + INTERVAL '1 day', 30),
(2, 'LOTE003', CURRENT_DATE + INTERVAL '210 days', 80),
(4, 'LOTE002', CURRENT_DATE - INTERVAL '200 days', 0)
ON CONFLICT DO NOTHING;


--INSERCIÓN DE VENTA, DETALLE Y AUDITORÍA

-- 1. Insertar la venta y guardar su ID
WITH nueva_venta AS (
    INSERT INTO ventas (receta_id, usuario)
    VALUES (10, 'usuario1')  -- Reemplazar '10' con el id real de la receta
    RETURNING id AS venta_id
)

-- 2. Insertar detalle de venta usando el ID de la venta
INSERT INTO detalles_venta (venta_id, lote_id, medicamento_id, cantidad, precio_unitario)
SELECT 
    nv.venta_id,         -- ID de la venta recién creada
    l.id,                -- ID del lote
    l.medicamento_id,    -- ID del medicamento
    5,                   -- Cantidad vendida
    m.precio             -- Precio del medicamento
FROM nueva_venta nv
JOIN lotes l ON l.lote_numero = 'LOTE001'
JOIN medicamentos m ON m.id = l.medicamento_id;

-- 3. Insertar auditoría si el medicamento es controlado
WITH ultima_venta AS (
    SELECT id AS venta_id FROM ventas ORDER BY id DESC LIMIT 1
)
INSERT INTO auditoria_controlados (
    venta_id, 
    medicamento_controlado_id, 
    paciente_id, 
    medico_id, 
    cantidad_dispensada, 
    usuario_que_dispenso, 
    numero_receta, 
    motivo_consulta
)
SELECT 
    uv.venta_id, 
    2,      -- ID del medicamento controlado (ejemplo)
    1,      -- ID del paciente
    1,      -- ID del médico
    3,      -- Cantidad dispensada
    'usuario1', 
    'REC001', 
    'Dolor crónico'
FROM ultima_venta uv;


--VER VENTA CREADA
SELECT * 
FROM ventas
ORDER BY id DESC
LIMIT 1;

-- VER DETALLE DE LA VENTA
SELECT dv.*, m.nombre AS medicamento, l.lote_numero
FROM detalles_venta dv
JOIN medicamentos m ON dv.medicamento_id = m.id
JOIN lotes l ON dv.lote_id = l.id
WHERE dv.venta_id = (SELECT id FROM ventas ORDER BY id DESC LIMIT 1);

--VER AUDITORIA
SELECT * 
FROM auditoria_controlados
WHERE venta_id = (SELECT id FROM ventas ORDER BY id DESC LIMIT 1);



-- EJEMPLOS DE USOY PRUEBAS DE FUNCIONALIDAD

--1) Llamar a la función transaccional para dispensar
SELECT * 
FROM fn_dispensar
(p_lote_id := 1, 
p_cantidad := 5, 
p_receta_id := 1,
p_paciente_id := 1,
p_medico_id := 1,
p_usuario := 'usuario1');

-- 2)  Ver alertas de lotes próximos a vencer (no procesadas)
SELECT a.*, l.lote_numero, m.nombre 
FROM alertas_vencimiento a 
JOIN lotes l ON a.lote_id = l.id 
JOIN medicamentos m ON l.medicamento_id = m.id
WHERE a.procesado = FALSE;


-- Requisito 6: Optimizacion de  consultas 

--  Optimizar consultas de inventario
SELECT 
m.nombre,
l.lote_numero, 
l.stock,
l.fecha_vencimiento,
  CASE WHEN l.fecha_vencimiento <= CURRENT_DATE + INTERVAL '30 days' THEN 'VENCE PRONTO'
       WHEN l.stock < 10 THEN 'STOCK BAJO'
       ELSE 'NORMAL'
	   END AS estado
 FROM medicamentos m JOIN lotes l ON m.id = l.medicamento_id
 ORDER BY l.fecha_vencimiento;

 -- ROTACIÓN DE PRODUCTOS (más vendidos)
SELECT 
    m.nombre,
    SUM(dv.cantidad) AS total_vendido,
    COUNT(dv.venta_id) AS veces_vendido
FROM detalles_venta dv
JOIN medicamentos m ON m.id = dv.medicamento_id
GROUP BY m.id, m.nombre
ORDER BY total_vendido DESC;

--Control de vencimientos  (alertas)
SELECT a.*, l.lote_numero, m.nombre
FROM alertas_vencimiento a 
JOIN lotes l ON a.lote_id = l.id 
JOIN medicamentos m ON l.medicamento_id = m.id
WHERE a.procesado = FALSE;


-- 2d) Revisar índices creados
 SELECT indexname, tablename 
 FROM pg_indexes 
 WHERE schemaname = 'public' 
 AND indexname LIKE 'idx%';


 --Probar ACID: dispensación
 
SELECT * FROM fn_dispensar(1, 10, 1, 1, 1, 'usuario_test');

-- Ver resultados
SELECT 'Stock actual en lote 1:' as info, stock FROM lotes WHERE id = 1;
SELECT 'Última venta:' as info, * FROM ventas ORDER BY id DESC LIMIT 1;
SELECT 'Detalle de venta:' as info, * FROM detalles_venta ORDER BY id DESC LIMIT 1;
SELECT 'Auditoría (si controlado):' as info, * FROM auditoria_controlados ORDER BY id DESC LIMIT 1;


--REQUISITO 5: Usuarios y vistas con niveles de acceso
INSERT INTO usuarios (username, rol, clave_desbloqueo) VALUES
('Mary', 'admin', 'clave_segura'), --puede ver datos cifrados
('juan', 'farmaceutico', NULL),--ve datos clínicos parciales
('pedro', 'invitado', NULL);--solo datos NO sensibles

----Solo cambiamos el usuario en la consulta.
-- creacion de vistas - admin
CREATE OR REPLACE VIEW vista_pacientes_admin AS
SELECT
    id,
    nombre,
    dni,
    pgp_sym_decrypt(direccion, 'clave_segura')::text AS direccion,
    pgp_sym_decrypt(telefono, 'clave_segura')::text AS telefono,
    pgp_sym_decrypt(alergias, 'clave_segura')::text AS alergias,
    pgp_sym_decrypt(historial_medico, 'clave_segura')::text AS historial_medico,
    fecha_registro
FROM pacientes;

CREATE OR REPLACE VIEW vista_recetas_admin AS
SELECT
    id,
    paciente_id,
    medico_id,
    fecha_emision,
    fecha_vencimiento,
    pgp_sym_decrypt(diagnostico, 'clave_segura')::text AS diagnostico,
    pgp_sym_decrypt(tratamiento, 'clave_segura')::text AS tratamiento,
    pgp_sym_decrypt(instrucciones, 'clave_segura')::text AS instrucciones,
    pgp_sym_decrypt(observaciones, 'clave_segura')::text AS observaciones,
    estado
FROM recetas;

---- Consultar vistas de administrador
SELECT * FROM vista_pacientes_admin;
SELECT * FROM vista_recetas_admin;



-- Vistas para farmacéutico
CREATE OR REPLACE VIEW vista_pacientes_farmaceutico AS
SELECT
    id,
    nombre,
    dni,
    pgp_sym_decrypt(alergias, 'clave_segura')::text AS alergias, -- permitido
    fecha_registro
FROM pacientes;
--Consultar vistas
SELECT * FROM vista_pacientes_farmaceutico;
SELECT * FROM vista_recetas_farmaceutico;



--  Vistas para invitado
CREATE OR REPLACE VIEW vista_pacientes_invitado AS
SELECT
    id,
    nombre,
    dni
FROM pacientes;

--Consultar vistas
SELECT * FROM vista_pacientes_invitado;
SELECT * FROM vista_recetas_invitado;
