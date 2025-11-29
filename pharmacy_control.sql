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
CREATE TABLE IF NOT EXISTS pacientes  (
    id SERIAL PRIMARY KEY,
    nombre VARCHAR(255),                   -- Visible
    dni VARCHAR(8) UNIQUE,                 -- Visible
    direccion TEXT,                        -- Datos sensibles (sin encriptar por ahora)
    telefono TEXT,                         -- Datos sensibles
    alergias TEXT,                         -- Datos sensibles
    historial_medico TEXT,                 -- Datos sensibles
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 5. recetas (sin encriptación, campos TEXT)
CREATE TABLE IF NOT EXISTS recetas (
    id SERIAL PRIMARY KEY,
    paciente_id INT REFERENCES pacientes(id),
    medico_id INT REFERENCES medicos(id),
    fecha_emision DATE DEFAULT CURRENT_DATE,
    fecha_vencimiento DATE,
    diagnostico TEXT,
    tratamiento TEXT,
    instrucciones TEXT,
    observaciones TEXT,
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


-- ÍNDICES  PARA REQUISITO 2
CREATE INDEX idx_medicamentos ON medicamentos USING btree(nombre, tipo);
CREATE INDEX idx_lotes ON lotes USING btree(medicamento_id, fecha_vencimiento);
CREATE INDEX idx_fechas_vencimiento ON lotes USING btree(fecha_vencimiento) WHERE stock > 0;
CREATE INDEX idx_recetas ON recetas USING btree(paciente_id, fecha_emision);

-- Trigger REQUISITO 4
--1 
CREATE OR REPLACE FUNCTION alerta_vencimiento() RETURNS TRIGGER AS $$
DECLARE
    dias int;
    existe_alerta boolean;
    vencimiento_date date;
BEGIN
    vencimiento_date := NEW.fecha_vencimiento::date;
    dias := (vencimiento_date - CURRENT_DATE);

    IF (dias <= 30) AND NEW.stock > 0 THEN
        SELECT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE lote_id = NEW.id AND procesado = FALSE
        ) INTO existe_alerta;

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
--2
DROP TRIGGER IF EXISTS trigger_alerta_vencimiento ON lotes;
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF fecha_vencimiento, stock ON lotes
FOR EACH ROW EXECUTE FUNCTION alerta_vencimiento();



/*
-- Función transaccional para dispensar (ACID) 
-- - Verifica stock
-- - Resta stock en lote
-- - Crea venta y detalle
-- - Si medicamento es 'Controlado' inserta registro en auditoría_controlados
Atomicidad: Todo se ejecuta o nada (rollback si error).
Consistencia: Datos válidos (verifica stock, tipos).
Aislamiento: FOR UPDATE bloquea filas para evitar race conditions.
Durabilidad: Cambios permanentes en DB.

*/
CREATE OR REPLACE FUNCTION alerta_vencimiento() RETURNS TRIGGER AS $$
DECLARE
    dias int;
    existe_alerta boolean;
    vencimiento_date date;
BEGIN
    -- normalizar fecha (si NEW.fecha_vencimiento es timestamp/date)
    vencimiento_date := NEW.fecha_vencimiento::date;
    dias := (vencimiento_date - CURRENT_DATE);

    IF (dias <= 30) AND NEW.stock > 0 THEN
        SELECT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE lote_id = NEW.id AND procesado = FALSE
        ) INTO existe_alerta;

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

DROP TRIGGER IF EXISTS trigger_alerta_vencimiento ON lotes;
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF fecha_vencimiento, stock ON lotes
FOR EACH ROW EXECUTE FUNCTION alerta_vencimiento();

-- ------------------------------------------------------------
-- Función transaccional para dispensar (ACID) — uso del FOR UPDATE
-- - Verifica stock
-- - Resta stock en lote
-- - Crea venta y detalle
-- - Si medicamento es 'Controlado' inserta registro en auditoría_controlados
-- ------------------------------------------------------------
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

    IF v_stock < p_cantidad THEN
        RETURN QUERY SELECT 'ERROR: stock insuficiente'::text, NULL::int;
        RETURN;
    END IF;

    -- Obtener precio sugerido (ultimo precio del medicamento)
    SELECT precio INTO v_precio FROM medicamentos WHERE id = v_med_id;

    -- Restar stock
    UPDATE lotes SET stock = stock - p_cantidad WHERE id = p_lote_id;

    -- Insertar venta y detalle
    INSERT INTO ventas (receta_id, usuario) VALUES (p_receta_id, p_usuario) RETURNING id INTO v_venta_id;

    INSERT INTO detalles_venta (venta_id, lote_id, medicamento_id, cantidad, precio_unitario)
    VALUES (v_venta_id, p_lote_id, v_med_id, p_cantidad, v_precio);

    -- Si es medicamento controlado, insertar auditoría específica
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
-- Medicamentos
INSERT INTO medicamentos (nombre, tipo, descripcion, precio) VALUES 
('Aspirina', 'Común', 'Analgésico', 2.50),
('Codeína', 'Controlado', 'Analgésico fuerte', 12.00),
('Ibuprofeno', 'Común', 'Antiinflamatorio', 3.00),
('Amoxicilina', 'Controlado', 'Antibiótico', 8.00)
ON CONFLICT DO NOTHING;

-- Médicos
INSERT INTO medicos (nombre, especialidad, cmp) VALUES
('Dr. Juan Pérez', 'Medicina General', 'CMP001'),
('Dra. María López', 'Pediatría', 'CMP002')
ON CONFLICT DO NOTHING;


-- Pacientes
INSERT INTO pacientes (nombre, dni, direccion, telefono, alergias, historial_medico) VALUES 
('Juan Pérez', '12345678', 'Calle 123', '987654321', 'Ninguna', 'Cirugía 2020'),
('María López', '87654321', 'Av. Principal', '999888777', 'Penicilina', 'Diabetes'),
('Carlos García', '11223344', 'Plaza Central', '888777666', 'Sulfa', 'Fractura')
ON CONFLICT DO NOTHING;


-- Recetas
INSERT INTO recetas (paciente_id, medico_id, fecha_emision, fecha_vencimiento, diagnostico, tratamiento, instrucciones) VALUES 
(1, 1, CURRENT_DATE - INTERVAL '60 days', CURRENT_DATE - INTERVAL '30 days', 'Dolor de cabeza', 'Tomar aspirina', 'Cada 8 horas'),
(2, 2, CURRENT_DATE - INTERVAL '45 days', CURRENT_DATE + INTERVAL '16 days', 'Fiebre', 'Reposo', 'Tomar líquidos')
ON CONFLICT DO NOTHING;


-- LOTES
INSERT INTO lotes (medicamento_id, lote_numero, fecha_vencimiento, stock) VALUES
(1, 'LOTE001', CURRENT_DATE + INTERVAL '16 days', 100),
(3, 'LOTE004', CURRENT_DATE + INTERVAL '1 day', 30),
(2, 'LOTE003', CURRENT_DATE + INTERVAL '210 days', 80),
(4, 'LOTE002', CURRENT_DATE - INTERVAL '200 days', 0)
ON CONFLICT DO NOTHING;


---INSERCION DE VENTA
-- Insertar una venta de prueba
INSERT INTO ventas (receta_id, usuario) VALUES (1, 'usuario1') ON CONFLICT DO NOTHING;

-- Insertar detalle de venta
INSERT INTO detalles_venta (venta_id, lote_id, medicamento_id, cantidad, precio_unitario)
SELECT v.id, l.id, l.medicamento_id, 5, m.precio
FROM ventas v JOIN recetas r ON v.receta_id = r.id
JOIN lotes l ON l.lote_numero = 'LOTE001'
JOIN medicamentos m ON m.id = l.medicamento_id
WHERE v.id = (SELECT id FROM ventas LIMIT 1)
ON CONFLICT DO NOTHING;

-- Insertar auditoría ejemplo
INSERT INTO auditoria_controlados (venta_id, medicamento_controlado_id, paciente_id, medico_id, cantidad_dispensada, usuario_que_dispenso, numero_receta, motivo_consulta)
VALUES ((SELECT id FROM ventas LIMIT 1), 2, 1, 1, 3, 'usuario1', 'REC001', 'Dolor crónico')
ON CONFLICT DO NOTHING;

-- ------------------------------------------------------------
-- EJEMPLOS DE USO
-- ------------------------------------------------------------
--1) Llamar a la función transaccional para dispensar
SELECT * FROM fn_dispensar(p_lote_id := 1, p_cantidad := 5, p_receta_id := 1, p_paciente_id := 1, p_medico_id := 1, p_usuario := 'usuario1');

-- 2) Consultas útiles
-- Ver alertas no procesadas
SELECT a.*, l.lote_numero, m.nombre FROM alertas_vencimiento a JOIN lotes l ON a.lote_id = l.id JOIN medicamentos m ON l.medicamento_id = m.id WHERE a.procesado = FALSE;

-- Ver inventario y estado
SELECT m.nombre, l.lote_numero, l.stock, l.fecha_vencimiento,
  CASE WHEN l.fecha_vencimiento <= CURRENT_DATE + INTERVAL '30 days' THEN 'VENCE PRONTO'
       WHEN l.stock < 10 THEN 'STOCK BAJO'
       ELSE 'NORMAL' END AS estado
 FROM medicamentos m JOIN lotes l ON m.id = l.medicamento_id
 ORDER BY l.fecha_vencimiento;

-- Mostrar índices
 SELECT indexname, tablename FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE 'idx%';


