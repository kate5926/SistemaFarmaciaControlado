

-- Extension
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- TABLAS PRINCIPALES

CREATE TABLE medicamentos (
    id_medicamento SERIAL PRIMARY KEY,
    codigo_barras VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(200) NOT NULL,
    principio_activo VARCHAR(200) NOT NULL,
    concentracion VARCHAR(100),
    forma_farmaceutica VARCHAR(100),
    laboratorio VARCHAR(150),
    es_controlado BOOLEAN DEFAULT FALSE,
    clasificacion_control VARCHAR(50), -- I, II, III, IV (DEA)
    requiere_receta BOOLEAN DEFAULT FALSE,
    precio_venta DECIMAL(10,2) NOT NULL,
    stock_minimo INTEGER DEFAULT 10,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    activo BOOLEAN DEFAULT TRUE
);

CREATE TABLE lotes_medicamentos (
    id_lote SERIAL PRIMARY KEY,
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    numero_lote VARCHAR(50) NOT NULL,
    fecha_fabricacion DATE NOT NULL,
    fecha_vencimiento DATE NOT NULL,
    cantidad_inicial INTEGER NOT NULL,
    cantidad_actual INTEGER NOT NULL,
    precio_compra DECIMAL(10,2) NOT NULL,
    proveedor VARCHAR(150),
    fecha_ingreso TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    estado VARCHAR(20) DEFAULT 'ACTIVO', -- ACTIVO, VENCIDO, RETIRADO
    UNIQUE(id_medicamento, numero_lote)
);

-- Tabla de Pacientes (datos encriptados)
CREATE TABLE pacientes (
    id_paciente SERIAL PRIMARY KEY,
    dni_encriptado BYTEA NOT NULL, -- DNI encriptado
    nombre_encriptado BYTEA NOT NULL,
    apellido_encriptado BYTEA NOT NULL,
    fecha_nacimiento_encriptada BYTEA,
    telefono_encriptado BYTEA,
    direccion_encriptada BYTEA,
    email VARCHAR(150),
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    activo BOOLEAN DEFAULT TRUE
);

-- Tabla de Médicos Prescriptores
CREATE TABLE medicos (
    id_medico SERIAL PRIMARY KEY,
    numero_colegiatura VARCHAR(50) UNIQUE NOT NULL,
    dni VARCHAR(20) NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    apellido VARCHAR(100) NOT NULL,
    especialidad VARCHAR(100),
    telefono VARCHAR(20),
    email VARCHAR(150),
    autorizado_controlados BOOLEAN DEFAULT FALSE,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    activo BOOLEAN DEFAULT TRUE
);

-- Tabla de Recetas Médicas
CREATE TABLE recetas_medicas (
    id_receta SERIAL PRIMARY KEY,
    numero_receta VARCHAR(50) UNIQUE NOT NULL,
    id_medico INTEGER REFERENCES medicos(id_medico),
    id_paciente INTEGER REFERENCES pacientes(id_paciente),
    fecha_emision DATE NOT NULL,
    fecha_vencimiento DATE NOT NULL,
    diagnostico_encriptado BYTEA,  
    observaciones_encriptadas BYTEA,
    estado VARCHAR(20) DEFAULT 'PENDIENTE', -- PENDIENTE, DISPENSADA, VENCIDA, ANULADA
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE detalle_recetas (
    id_detalle_receta SERIAL PRIMARY KEY,
    id_receta INTEGER REFERENCES recetas_medicas(id_receta),
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    cantidad_prescrita INTEGER NOT NULL,
    cantidad_dispensada INTEGER DEFAULT 0,
    posologia_encriptada BYTEA, -- Instrucciones de uso
    dispensado_completo BOOLEAN DEFAULT FALSE,
    fecha_dispensacion TIMESTAMP
);

CREATE TABLE ventas (
    id_venta SERIAL PRIMARY KEY,
    numero_venta VARCHAR(50) UNIQUE NOT NULL,
    id_receta INTEGER REFERENCES recetas_medicas(id_receta), -- NULL si no requiere receta
    id_paciente INTEGER REFERENCES pacientes(id_paciente),
    fecha_venta TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    subtotal DECIMAL(10,2) NOT NULL,
    descuento DECIMAL(10,2) DEFAULT 0,
    total DECIMAL(10,2) NOT NULL,
    metodo_pago VARCHAR(50),
    usuario_vendedor VARCHAR(100) NOT NULL,
    estado VARCHAR(20) DEFAULT 'COMPLETADA' -- COMPLETADA, ANULADA
);

CREATE TABLE detalle_ventas (
    id_detalle_venta SERIAL PRIMARY KEY,
    id_venta INTEGER REFERENCES ventas(id_venta),
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    id_lote INTEGER REFERENCES lotes_medicamentos(id_lote),
    cantidad INTEGER NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    subtotal DECIMAL(10,2) NOT NULL
);

-- Tabla de Auditoría de Medicamentos Controlados
CREATE TABLE auditoria_controlados (
    id_auditoria SERIAL PRIMARY KEY,
    id_venta INTEGER REFERENCES ventas(id_venta),
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    id_receta INTEGER REFERENCES recetas_medicas(id_receta) NOT NULL,
    id_medico INTEGER REFERENCES medicos(id_medico) NOT NULL,
    id_paciente INTEGER REFERENCES pacientes(id_paciente) NOT NULL,
    cantidad_dispensada INTEGER NOT NULL,
    numero_lote VARCHAR(50) NOT NULL,
    fecha_dispensacion TIMESTAMP NOT NULL,
    usuario_dispensador VARCHAR(100) NOT NULL,
    observaciones TEXT,
    datos_completos_encriptados BYTEA, -- JSON con toda la información
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE alertas_vencimiento (
    id_alerta SERIAL PRIMARY KEY,
    id_lote INTEGER REFERENCES lotes_medicamentos(id_lote),
    id_medicamento INTEGER REFERENCES medicamentos(id_medicamento),
    tipo_alerta VARCHAR(50), -- PROXIMO_VENCER, VENCIDO, STOCK_BAJO
    mensaje TEXT NOT NULL,
    fecha_vencimiento DATE,
    dias_restantes INTEGER,
    cantidad_afectada INTEGER,
    prioridad VARCHAR(20), -- ALTA, MEDIA, BAJA
    estado VARCHAR(20) DEFAULT 'ACTIVA', -- ACTIVA, ATENDIDA, IGNORADA
    fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fecha_atencion TIMESTAMP
);

-- ÍNDICES 
--Medicamentos
CREATE INDEX idx_medicamentos_busqueda 
ON medicamentos(nombre, principio_activo, es_controlado);
--lotes 
CREATE INDEX idx_lotes_medicamento_vencimiento 
ON lotes_medicamentos(id_medicamento, fecha_vencimiento, estado);
--Recetas 
CREATE INDEX idx_recetas_paciente_fecha 
ON recetas_medicas(id_paciente, fecha_emision, estado);
--Alertas
CREATE INDEX idx_alertas_prioridad_estado 
ON alertas_vencimiento(prioridad, estado, fecha_creacion);
-- Auditoria
CREATE INDEX idx_auditoria_fecha_medicamento 
ON auditoria_controlados(fecha_dispensacion, id_medicamento);


-- 4.Requisito 4: Alertas Automáticas de Vencimientos mediante Triggers

-- Función para generar alertas de vencimiento
CREATE OR REPLACE FUNCTION generar_alerta_vencimiento()
RETURNS TRIGGER AS $$
DECLARE
    dias_para_vencer INTEGER;
    tipo_alerta VARCHAR(50);
    mensaje_alerta TEXT;
    prioridad_alerta VARCHAR(20);
BEGIN
    -- Calcular días para vencimiento
    dias_para_vencer := NEW.fecha_vencimiento - CURRENT_DATE;
    
    -- Determinar tipo de alerta y prioridad
    IF dias_para_vencer <= 0 THEN
        tipo_alerta := 'VENCIDO';
        mensaje_alerta := 'Lote vencido: ' || NEW.numero_lote;
        prioridad_alerta := 'ALTA';
    ELSIF dias_para_vencer <= 30 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote próximo a vencer en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'ALTA';
    ELSIF dias_para_vencer <= 60 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote vence en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'MEDIA';
    ELSIF dias_para_vencer <= 90 THEN
        tipo_alerta := 'PROXIMO_VENCER';
        mensaje_alerta := 'Lote vence en ' || dias_para_vencer || ' días: ' || NEW.numero_lote;
        prioridad_alerta := 'BAJA';
    ELSE
        RETURN NEW; -- No generar alerta
    END IF;
    
    -- Insertar alerta si no existe una activa para este lote
    INSERT INTO alertas_vencimiento (
        id_lote, id_medicamento, tipo_alerta, mensaje, 
        fecha_vencimiento, dias_restantes, cantidad_afectada, prioridad
    )
    SELECT NEW.id_lote, NEW.id_medicamento, tipo_alerta, mensaje_alerta,
           NEW.fecha_vencimiento, dias_para_vencer, NEW.cantidad_actual, prioridad_alerta
    WHERE NOT EXISTS (
        SELECT 1 FROM alertas_vencimiento 
        WHERE id_lote = NEW.id_lote 
        AND estado = 'ACTIVA'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;



-- Trigger para alertas al insertar/actualizar lotes
CREATE TRIGGER trigger_alerta_vencimiento
AFTER INSERT OR UPDATE OF cantidad_actual, fecha_vencimiento ON lotes_medicamentos
FOR EACH ROW
WHEN (NEW.estado = 'ACTIVO')
EXECUTE FUNCTION generar_alerta_vencimiento();



-- Función para alerta de stock bajo
CREATE OR REPLACE FUNCTION alerta_stock_bajo()
RETURNS TRIGGER AS $$
DECLARE
    stock_total INTEGER;
    stock_min INTEGER;
BEGIN
    -- Calcular stock total del medicamento
    SELECT COALESCE(SUM(cantidad_actual), 0), m.stock_minimo
    INTO stock_total, stock_min
    FROM lotes_medicamentos l
    JOIN medicamentos m ON m.id_medicamento = l.id_medicamento
    WHERE l.id_medicamento = NEW.id_medicamento
    AND l.estado = 'ACTIVO'
    GROUP BY m.stock_minimo;
    
    -- Generar alerta si está bajo el mínimo
    IF stock_total <= stock_min THEN
        INSERT INTO alertas_vencimiento (
            id_medicamento, tipo_alerta, mensaje, 
            cantidad_afectada, prioridad, estado
        )
        SELECT NEW.id_medicamento, 'STOCK_BAJO',
               'Stock bajo: ' || m.nombre || ' (Stock: ' || stock_total || ', Mínimo: ' || stock_min || ')',
               stock_total, 'ALTA', 'ACTIVA'
        FROM medicamentos m
        WHERE m.id_medicamento = NEW.id_medicamento
        AND NOT EXISTS (
            SELECT 1 FROM alertas_vencimiento
            WHERE id_medicamento = NEW.id_medicamento
            AND tipo_alerta = 'STOCK_BAJO'
            AND estado = 'ACTIVA'
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Trigger para alerta de stock bajo
CREATE TRIGGER trigger_stock_bajo
AFTER UPDATE OF cantidad_actual ON lotes_medicamentos
FOR EACH ROW
EXECUTE FUNCTION alerta_stock_bajo();

----- PRUEVA DE TRIGGER 
--Insertar un lote que vence pronto
INSERT INTO lotes_medicamentos (
    id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, 
    cantidad_inicial, cantidad_actual, precio_compra, proveedor
) VALUES (
    1, 
    'LOTE-PRUEBA-VENCE-7DIAS',
    CURRENT_DATE - 10,               -- fabricación hace 10 días
    CURRENT_DATE + 7,                -- vence en 7 días
    10, 10, 2.00, 'Proveedor Test'
);
-- Prueba 2: Lote ya vencido
INSERT INTO lotes_medicamentos (
    id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, 
    cantidad_inicial, cantidad_actual, precio_compra, proveedor
) VALUES (
    1, 
    'LOTE-PRUEBA-VENCIDO',
    CURRENT_DATE - 100,              -- fabricación hace 100 días
    CURRENT_DATE - 5,                -- venció hace 5 días
    20, 20, 3.00, 'Proveedor Test'
);

---VERIFICACION : 
SELECT * FROM alertas_vencimiento 
ORDER BY fecha_creacion DESC 
LIMIT 10;
---
-- REQUISITO 3: "Control especial con auditoría para medicamentos controlados"
-- Función para auditoría automática de controlados
CREATE OR REPLACE FUNCTION auditar_medicamento_controlado()
RETURNS TRIGGER AS $$
DECLARE
    med_record RECORD;
    rec_record RECORD;
    datos_json JSONB;
BEGIN
    -- Verificar si el medicamento es controlado
    SELECT m.*, l.numero_lote
    INTO med_record
    FROM medicamentos m
    JOIN lotes_medicamentos l ON l.id_lote = NEW.id_lote
    WHERE m.id_medicamento = NEW.id_medicamento
    AND m.es_controlado = TRUE;
    
    IF FOUND THEN
        -- Obtener datos de la receta
        SELECT r.*, m.numero_colegiatura, m.nombre as medico_nombre,
               p.id_paciente
        INTO rec_record
        FROM ventas v
        LEFT JOIN recetas_medicas r ON r.id_receta = v.id_receta
        LEFT JOIN medicos m ON m.id_medico = r.id_medico
        LEFT JOIN pacientes p ON p.id_paciente = r.id_paciente
        WHERE v.id_venta = NEW.id_venta;
        
        -- Crear JSON con datos completos
        datos_json := jsonb_build_object(
            'medicamento', med_record.nombre,
            'lote', med_record.numero_lote,
            'cantidad', NEW.cantidad,
            'clasificacion', med_record.clasificacion_control,
            'receta', rec_record.numero_receta,
            'medico_colegiatura', rec_record.numero_colegiatura
        );
        
        -- Insertar auditoría
        INSERT INTO auditoria_controlados (
            id_venta, id_medicamento, id_receta, id_medico, id_paciente,
            cantidad_dispensada, numero_lote, fecha_dispensacion,
            usuario_dispensador, datos_completos_encriptados
        )
        VALUES (
            NEW.id_venta, NEW.id_medicamento, rec_record.id_receta,
            rec_record.id_medico, rec_record.id_paciente,
            NEW.cantidad, med_record.numero_lote, CURRENT_TIMESTAMP,
            (SELECT usuario_vendedor FROM ventas WHERE id_venta = NEW.id_venta),
            pgp_sym_encrypt(datos_json::text, 'clave_segura_auditorias')
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para auditoría automática
CREATE TRIGGER trigger_auditoria_controlados
AFTER INSERT ON detalle_ventas
FOR EACH ROW
EXECUTE FUNCTION auditar_medicamento_controlado();

--6. Optimizar consultas de inventario, rotación de productos y control de vencimientos.
-- Optimizar consultas de inventario
SELECT 
    m.nombre,
    m.codigo_barras,
    lm.numero_lote,
    lm.cantidad_actual as stock,
    lm.fecha_vencimiento,
    CASE 
        WHEN lm.fecha_vencimiento <= CURRENT_DATE THEN 'VENCIDO'
        WHEN lm.fecha_vencimiento <= CURRENT_DATE + INTERVAL '30 days' THEN 'VENCE PRONTO'
        WHEN lm.cantidad_actual <= m.stock_minimo THEN 'STOCK BAJO'
        ELSE 'NORMAL'
    END AS estado
FROM medicamentos m 
JOIN lotes_medicamentos lm ON m.id_medicamento = lm.id_medicamento
WHERE lm.estado = 'ACTIVO'
ORDER BY lm.fecha_vencimiento;

-- ROTACIÓN DE PRODUCTOS (más vendidos)
SELECT 
    m.nombre,
    m.codigo_barras,
    SUM(dv.cantidad) AS total_vendido,
    COUNT(DISTINCT dv.id_venta) AS veces_vendido,
    AVG(dv.cantidad) AS promedio_por_venta,
    SUM(dv.subtotal) AS ingresos_totales
FROM detalle_ventas dv
JOIN medicamentos m ON m.id_medicamento = dv.id_medicamento
GROUP BY m.id_medicamento, m.nombre, m.codigo_barras
ORDER BY total_vendido DESC;

-- Control de vencimientos (alertas)
SELECT 
    a.id_alerta,
    a.tipo_alerta,
    a.prioridad,
    m.nombre as medicamento,
    lm.numero_lote,
    lm.fecha_vencimiento,
    a.dias_restantes,
    a.mensaje,
    a.fecha_creacion
FROM alertas_vencimiento a 
JOIN lotes_medicamentos lm ON a.id_lote = lm.id_lote
JOIN medicamentos m ON lm.id_medicamento = m.id_medicamento
WHERE a.estado = 'ACTIVA'
ORDER BY 
    CASE a.prioridad 
        WHEN 'ALTA' THEN 1
        WHEN 'MEDIA' THEN 2 
        WHEN 'BAJA' THEN 3
    END,
    lm.fecha_vencimiento ASC;

-- Optimizar consultas de inventario 
SELECT 
    m.id_medicamento,
    m.nombre,
    m.stock_minimo,
    COALESCE(SUM(lm.cantidad_actual), 0) as stock_total,
    COUNT(lm.id_lote) as total_lotes_activos,
    CASE 
        WHEN COALESCE(SUM(lm.cantidad_actual), 0) = 0 THEN 'SIN STOCK'
        WHEN COALESCE(SUM(lm.cantidad_actual), 0) <= m.stock_minimo THEN 'STOCK BAJO'
        ELSE 'STOCK SUFICIENTE'
    END as estado_inventario
FROM medicamentos m
LEFT JOIN lotes_medicamentos lm ON m.id_medicamento = lm.id_medicamento 
    AND lm.estado = 'ACTIVO'
WHERE m.activo = TRUE
GROUP BY m.id_medicamento, m.nombre, m.stock_minimo
ORDER BY estado_inventario, stock_total ASC



--REQUISITO 1: FUNCIÓN DISPENSAR (TRANSACCIONES ACID)

CREATE OR REPLACE FUNCTION fn_dispensar(
    p_id_lote INTEGER,
    p_cantidad INTEGER,
    p_id_receta INTEGER,
    p_id_paciente INTEGER,
    p_id_medico INTEGER,
    p_usuario VARCHAR(100)
) RETURNS TABLE(resultado TEXT, id_venta_generada INTEGER) AS $$
DECLARE
    v_stock_actual INTEGER;
    v_id_medicamento INTEGER;
    v_precio_venta DECIMAL(10,2);
    v_nueva_venta_id INTEGER;
    v_medicamento_nombre VARCHAR(200);
    v_requiere_receta BOOLEAN;
    v_receta_valida BOOLEAN;
    v_numero_venta VARCHAR(50);
BEGIN
    -- Validación básica
    IF p_cantidad <= 0 THEN
        RETURN QUERY SELECT 'ERROR: La cantidad debe ser mayor a 0'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- BLOQUEO SIMULTÁNEO de lote Y receta (si aplica)
    IF p_id_receta IS NOT NULL THEN
        -- Verificar y bloquear receta primero
        SELECT EXISTS (
            SELECT 1 FROM recetas_medicas 
            WHERE id_receta = p_id_receta 
            AND estado = 'PENDIENTE'
            AND fecha_vencimiento >= CURRENT_DATE
            FOR UPDATE  -- BLOQUEO DE RECETA
        ) INTO v_receta_valida;
        
        IF NOT v_receta_valida THEN
            RETURN QUERY SELECT 'ERROR: Receta no válida'::TEXT, NULL::INTEGER;
            RETURN;
        END IF;
    END IF;

    -- Bloquear lote
    SELECT lm.cantidad_actual, lm.id_medicamento, m.precio_venta, m.nombre, m.requiere_receta
    INTO v_stock_actual, v_id_medicamento, v_precio_venta, v_medicamento_nombre, v_requiere_receta
    FROM lotes_medicamentos lm
    JOIN medicamentos m ON m.id_medicamento = lm.id_medicamento
    WHERE lm.id_lote = p_id_lote 
    AND lm.estado = 'ACTIVO'
    FOR UPDATE;  -- BLOQUEO DE LOTE

    -- Verificar lote
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'ERROR: Lote no encontrado'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- Verificar stock
    IF v_stock_actual < p_cantidad THEN
        RETURN QUERY SELECT 'ERROR: Stock insuficiente. Stock: ' || v_stock_actual::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- Verificar receta para medicamentos que la requieren
    IF v_requiere_receta AND p_id_receta IS NULL THEN
        RETURN QUERY SELECT 'ERROR: Medicamento requiere receta'::TEXT, NULL::INTEGER;
        RETURN;
    END IF;

    -- EJECUCIÓN DE LA TRANSACCIÓN
    BEGIN
        -- 1. Actualizar stock
        UPDATE lotes_medicamentos 
        SET cantidad_actual = cantidad_actual - p_cantidad
        WHERE id_lote = p_id_lote;

        -- 2. Generar número de venta único
        v_numero_venta := 'VENTA-' || TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDD-HH24MISS-MS');
        
        -- 3. Crear venta
        INSERT INTO ventas (
            numero_venta, id_receta, id_paciente, subtotal, total, usuario_vendedor
        ) VALUES (
            v_numero_venta, p_id_receta, p_id_paciente, 
            v_precio_venta * p_cantidad, v_precio_venta * p_cantidad, p_usuario
        ) RETURNING id_venta INTO v_nueva_venta_id;

        -- 4. Crear detalle de venta
        INSERT INTO detalle_ventas (
            id_venta, id_medicamento, id_lote, cantidad, precio_unitario, subtotal
        ) VALUES (
            v_nueva_venta_id, v_id_medicamento, p_id_lote, p_cantidad,
            v_precio_venta, v_precio_venta * p_cantidad
        );

        -- 5. Actualizar receta (si aplica)
        IF p_id_receta IS NOT NULL THEN
            UPDATE recetas_medicas 
            SET estado = 'DISPENSADA'
            WHERE id_receta = p_id_receta;

            UPDATE detalle_recetas 
            SET cantidad_dispensada = cantidad_dispensada + p_cantidad,
                dispensado_completo = (cantidad_dispensada + p_cantidad >= cantidad_prescrita),
                fecha_dispensacion = CURRENT_TIMESTAMP
            WHERE id_receta = p_id_receta 
            AND id_medicamento = v_id_medicamento;
        END IF;

        -- ÉXITO
        RETURN QUERY SELECT 'OK: Venta exitosa - ' || v_medicamento_nombre::TEXT, v_nueva_venta_id;

    EXCEPTION
        WHEN unique_violation THEN
            RETURN QUERY SELECT 'ERROR: Número de venta duplicado'::TEXT, NULL::INTEGER;
        WHEN OTHERS THEN
            RETURN QUERY SELECT 'ERROR: ' || SQLERRM::TEXT, NULL::INTEGER;
    END;

END;
$$ LANGUAGE plpgsql;

--PARA PROBAR 
--Atomicidad : Prueba 1: Intentar dispensar más stock del que hay
SELECT * FROM fn_dispensar(
    p_id_lote := 2,  -- LOTE-PARA-2024-01 (Paracetamol)
    p_cantidad := 9999,
    p_id_receta := NULL,
    p_id_paciente := 2,  
    p_id_medico := NULL,
    p_usuario := 'farmaceutico_ana'
);
--VEIFICAR
SELECT cantidad_actual 
FROM lotes_medicamentos WHERE id_lote = 2;

SELECT COUNT(*) FROM ventas;

SELECT * FROM ventas ORDER BY id_venta DESC LIMIT 10;

--------CONSISTENCIA
--Prueba 2: Intentar dispensar cantidad negativa
SELECT * FROM fn_dispensar(
    p_id_lote := 7,
    p_cantidad := 9999,
    p_id_receta := NULL,
    p_id_paciente := 1,
    p_id_medico := NULL,
    p_usuario := 'farmaceutico_maria'
);
--verificacion
SELECT cantidad_actual 
FROM lotes_medicamentos WHERE id_lote = 7;


-----AISLAMIENTO
/*CONTEXTO : 
Porque dos farmacéuticos 
pueden intentar dispensar el MISMO lote al mismo tiempo.
paso 1 : abrir dos transacciones manuales: */


INSERT INTO lotes_medicamentos (
    id_medicamento,
    numero_lote,
    fecha_fabricacion,
    fecha_vencimiento,
    cantidad_inicial,
    cantidad_actual,
    precio_compra,
    proveedor
) VALUES (
    1,                      -- Usa un medicamento existente (Paracetamol)
    'LOTE-TEST-ISO-01',     -- Nombre del lote para pruebas
    '2024-11-01',
    '2025-11-01',
    1,                      -- Cantidad inicial
    1,                      -- Cantidad actual
    1.50,
    'Proveedor de Pruebas'
);


--SESION A
BEGIN;
SELECT * FROM fn_dispensar(
    p_id_lote := 2,
    p_cantidad := 1,
    p_id_receta := NULL,
    p_id_paciente := 1,
    p_usuario := 'farmaceutico_maria'
);
SELECT pg_sleep(15);


--SESION  quedará BLOQUEADA esperando
BEGIN;

SELECT * FROM fn_dispensar(
    p_id_lote := 2,
    p_cantidad := 1,
    p_id_receta := NULL,
    p_id_paciente := 2,
    p_usuario := 'farmaceutico_carlos'
);


-- DATOS DE PRUEBA
-- Insertar medicamentos 
INSERT INTO medicamentos (codigo_barras, nombre, principio_activo, concentracion, forma_farmaceutica, laboratorio, es_controlado, clasificacion_control, requiere_receta, precio_venta, stock_minimo) VALUES
('7501234567890', 'Paracetamol', 'Acetaminofén', '500 mg', 'Tableta', 'Genfar', FALSE, NULL, FALSE, 2.50, 50),
('7501234567891', 'Ibuprofeno', 'Ibuprofeno', '400 mg', 'Tableta', 'Bayer', FALSE, NULL, FALSE, 3.00, 40),
('7501234567892', 'Amoxicilina', 'Amoxicilina', '500 mg', 'Cápsula', 'Pfizer', FALSE, NULL, TRUE, 8.50, 30),
('7501234567893', 'Codeína', 'Fosfato de Codeína', '30 mg', 'Tableta', 'Roche', TRUE, 'II', TRUE, 15.00, 20),
('7501234567894', 'Diazepam', 'Diazepam', '5 mg', 'Tableta', 'Valium', TRUE, 'IV', TRUE, 12.00, 15),
('7501234567895', 'Omeprazol', 'Omeprazol', '20 mg', 'Cápsula', 'AstraZeneca', FALSE, NULL, FALSE, 6.00, 35),
('7501234567896', 'Atorvastatina', 'Atorvastatina', '40 mg', 'Tableta', 'Pfizer', FALSE, NULL, TRUE, 18.00, 25),
('7501234567897', 'Metformina', 'Clorhidrato de Metformina', '850 mg', 'Tableta', 'Merck', FALSE, NULL, TRUE, 7.50, 45),
('7501234567898', 'Loratadina', 'Loratadina', '10 mg', 'Tableta', 'Schering-Plough', FALSE, NULL, FALSE, 4.00, 60),
('7501234567899', 'Salbutamol', 'Sulfato de Salbutamol', '100 mcg', 'Inhalador', 'GSK', FALSE, NULL, TRUE, 22.00, 20);

--LOTES
INSERT INTO lotes_medicamentos (id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, cantidad_inicial, cantidad_actual, precio_compra, proveedor) VALUES
(1, 'LOTE-PARA-2024-01', '2024-01-15', '2025-07-15', 500, 350, 1.80, 'Distribuidora Médica SA'),
(1, 'LOTE-PARA-2024-02', '2024-03-20', '2025-09-20', 300, 200, 1.75, 'Distribuidora Médica SA'),
(2, 'LOTE-IBU-2024-01', '2024-02-10', '2025-08-10', 400, 280, 2.20, 'Farmacéutica Nacional'),
(3, 'LOTE-AMOX-2024-01', '2024-01-30', '2025-01-30', 200, 120, 6.00, 'Pfizer Distribución'),
(4, 'LOTE-CODE-2024-01', '2024-03-01', '2025-03-01', 100, 75, 10.50, 'Controlados SA'),
(4, 'LOTE-CODE-2024-02', '2024-04-15', '2025-04-15', 80, 80, 10.80, 'Controlados SA'),
(5, 'LOTE-DIAZ-2024-01', '2024-02-20', '2025-08-20', 120, 90, 8.50, 'Especialidades Farmacéuticas'),
(6, 'LOTE-OME-2024-01', '2024-03-10', '2025-09-10', 300, 250, 4.20, 'AstraZeneca Perú'),
(7, 'LOTE-ATOR-2024-01', '2024-01-25', '2025-07-25', 150, 100, 14.00, 'Pfizer Distribución'),
(8, 'LOTE-MET-2024-01', '2024-02-05', '2025-02-05', 400, 320, 5.50, 'Merck Perú'),
(9, 'LOTE-LORA-2024-01', '2024-03-15', '2025-09-15', 600, 500, 2.80, 'Schering-Plough'),
(10, 'LOTE-SALB-2024-01', '2024-01-20', '2025-01-20', 100, 60, 16.00, 'GSK Perú');

INSERT INTO lotes_medicamentos (id_medicamento, numero_lote, fecha_fabricacion, fecha_vencimiento, cantidad_inicial, cantidad_actual, precio_compra, proveedor) VALUES
(1, 'LOTE-PARA-VENCE-01', '2023-06-01', CURRENT_DATE + INTERVAL '15 days', 100, 45, 1.70, 'Distribuidora Médica SA'),
(2, 'LOTE-IBU-VENCE-01', '2023-07-01', CURRENT_DATE + INTERVAL '5 days', 80, 20, 2.10, 'Farmacéutica Nacional'),
(3, 'LOTE-AMOX-VENCE-01', '2023-05-15', CURRENT_DATE - INTERVAL '10 days', 50, 15, 5.80, 'Pfizer Distribución');


INSERT INTO medicos (numero_colegiatura, dni, nombre, apellido, especialidad, telefono, email, autorizado_controlados) VALUES
('CMP-12345', '12345678', 'Carlos', 'Gutiérrez', 'Medicina General', '987654321', 'c.gutierrez@clinica.com', TRUE),
('CMP-23456', '23456789', 'Ana', 'Rodríguez', 'Pediatría', '987654322', 'a.rodriguez@clinica.com', TRUE),
('CMP-34567', '34567890', 'Luis', 'Fernández', 'Cardiología', '987654323', 'l.fernandez@clinica.com', FALSE),
('CMP-45678', '45678901', 'María', 'López', 'Ginecología', '987654324', 'm.lopez@clinica.com', TRUE),
('CMP-56789', '56789012', 'Jorge', 'Martínez', 'Traumatología', '987654325', 'j.martinez@clinica.com', FALSE);

-- Usando conversión directa a bytea
INSERT INTO pacientes (dni_encriptado, nombre_encriptado, apellido_encriptado, fecha_nacimiento_encriptada, telefono_encriptado, direccion_encriptada, email) VALUES
('12345678'::bytea, 'Juan'::bytea, 'Pérez'::bytea, '1985-03-15'::bytea, '987123456'::bytea, 'Av. Primavera 123'::bytea, 'juan.perez@email.com'),
('87654321'::bytea, 'María'::bytea, 'Gómez'::bytea, '1990-07-22'::bytea, '987123457'::bytea, 'Calle Los Olivos 456'::bytea, 'maria.gomez@email.com'),
('11223344'::bytea, 'Carlos'::bytea, 'López'::bytea, '1978-11-30'::bytea, '987123458'::bytea, 'Jr. Unión 789'::bytea, 'carlos.lopez@email.com'),
('55667788'::bytea, 'Laura'::bytea, 'Díaz'::bytea, '1988-05-10'::bytea, '987123459'::bytea, 'Av. Central 321'::bytea, 'laura.diaz@email.com'),
('99887766'::bytea, 'Roberto'::bytea, 'Silva'::bytea, '1975-12-03'::bytea, '987123460'::bytea, 'Psje. Libertad 654'::bytea, 'roberto.silva@email.com');


INSERT INTO recetas_medicas (numero_receta, id_medico, id_paciente, fecha_emision, fecha_vencimiento, diagnostico_encriptado, observaciones_encriptadas, estado) VALUES
('REC-2024-001', 1, 1, CURRENT_DATE - INTERVAL '5 days', CURRENT_DATE + INTERVAL '25 days', 'Infección respiratoria superior'::bytea, 'Reposo y abundante líquidos'::bytea, 'PENDIENTE'),
('REC-2024-002', 2, 2, CURRENT_DATE - INTERVAL '3 days', CURRENT_DATE + INTERVAL '27 days', 'Control de diabetes tipo 2'::bytea, 'Controlar glucemia en ayunas'::bytea, 'DISPENSADA'),
('REC-2024-003', 1, 3, CURRENT_DATE - INTERVAL '10 days', CURRENT_DATE + INTERVAL '20 days', 'Dolor lumbar crónico'::bytea, 'Evitar cargar peso'::bytea, 'PENDIENTE'),
('REC-2024-004', 4, 4, CURRENT_DATE - INTERVAL '1 day', CURRENT_DATE + INTERVAL '29 days', 'Ansiedad generalizada'::bytea, 'Sesión de terapia semanal'::bytea, 'PENDIENTE'),
('REC-2024-005', 3, 5, CURRENT_DATE - INTERVAL '7 days', CURRENT_DATE + INTERVAL '23 days', 'Hipertensión arterial'::bytea, 'Control de presión 2 veces al día'::bytea, 'DISPENSADA');

INSERT INTO detalle_recetas (id_receta, id_medicamento, cantidad_prescrita, cantidad_dispensada, posologia_encriptada, dispensado_completo) VALUES
(1, 3, 20, 0, 'Tomar 1 cápsula cada 8 horas por 7 días'::bytea, FALSE),
(1, 1, 10, 0, 'Tomar 1 tableta cada 6 horas si hay fiebre'::bytea, FALSE),
(2, 7, 30, 30, 'Tomar 1 tableta en la noche'::bytea, TRUE),
(2, 8, 60, 60, 'Tomar 1 tableta con el desayuno y cena'::bytea, TRUE),
(3, 4, 15, 0, 'Tomar 1 tableta cada 12 horas por dolor'::bytea, FALSE),
(4, 5, 30, 0, 'Tomar 1 tableta al acostarse'::bytea, FALSE),
(5, 6, 30, 30, 'Tomar 1 cápsula en ayunas'::bytea, TRUE);

INSERT INTO ventas (numero_venta, id_receta, id_paciente, subtotal, descuento, total, metodo_pago, usuario_vendedor) VALUES
('VENTA-2024-001', 2, 2, 255.00, 0, 255.00, 'EFECTIVO', 'farmaceutico_maria'),
('VENTA-2024-002', 5, 5, 180.00, 10.00, 170.00, 'TARJETA', 'farmaceutico_carlos'),
('VENTA-2024-003', NULL, 1, 15.00, 0, 15.00, 'EFECTIVO', 'farmaceutico_maria'),
('VENTA-2024-004', NULL, 3, 24.00, 0, 24.00, 'EFECTIVO', 'farmaceutico_ana'),
('VENTA-2024-005', NULL, 4, 8.50, 0, 8.50, 'TARJETA', 'farmaceutico_carlos');

INSERT INTO detalle_ventas (id_venta, id_medicamento, id_lote, cantidad, precio_unitario, subtotal) VALUES
(1, 7, 9, 30, 18.00, 540.00),
(1, 8, 10, 60, 7.50, 450.00),
(2, 6, 8, 30, 6.00, 180.00),
(3, 1, 1, 5, 2.50, 12.50),
(3, 2, 3, 1, 3.00, 3.00),
(4, 9, 11, 6, 4.00, 24.00),
(5, 1, 1, 3, 2.50, 7.50),
(5, 10, 12, 0.5, 22.00, 11.00);
