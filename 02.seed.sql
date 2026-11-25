-- ============================================================================
-- SMART INVENTORY - 02_seed.sql
-- Datos semilla con casos límite + 5 pruebas de integridad referencial/dominio
-- ============================================================================

BEGIN;

-- 1. Bodegas (2 almacenes)
INSERT INTO bodega (codigo, nombre) VALUES
                                        ('BOD-NORTE', 'Bodega Principal Quito Norte'),
                                        ('BOD-SUR',   'Centro de Distribución Quito Sur');

-- 2. Ubicaciones por bodega
INSERT INTO ubicacion (warehouse_id, codigo, zona, tipo) VALUES
                                                             (1, 'A-01-P1', 'Refrigerados', 'PICKING'),
                                                             (1, 'A-02-S1', 'Secos',        'ALMACENAJE'),
                                                             (1, 'M-99-01', 'Cuarentena',   'MERMA'),
                                                             (2, 'B-01-P1', 'General',      'PICKING'),
                                                             (2, 'B-02-S1', 'Reserva',      'ALMACENAJE');

-- 3. Proveedores
INSERT INTO proveedor (codigo, nombre) VALUES
                                           ('PROV-01', 'Distribuidora Andina S.A.'),
                                           ('PROV-02', 'Insumos Médicos del Pacífico');

-- 4. Productos (incluye perecibles, no perecibles, bajo mínimo y sin stock)
INSERT INTO producto (sku_code, nombre, unidad, stock_minimo, stock_objetivo, default_supplier_id, activo) VALUES
                                                                                                               ('SKU-VAC-01', 'Reactivo Biológico 50ml',      'FRASCO', 40, 120, 2, TRUE),
                                                                                                               ('SKU-SUE-02', 'Suero Fisiológico 1000ml',     'BOLSA',  50, 150, 2, TRUE),
                                                                                                               ('SKU-GUA-03', 'Guantes Nitrilo Caja x100',    'CAJA',   30, 100, 1, TRUE),
                                                                                                               ('SKU-JER-04', 'Jeringa Descartable 5ml',      'CAJA',   25,  80, 1, TRUE),
                                                                                                               ('SKU-OBS-99', 'Termómetro Mercurio (Legacy)', 'UND',     0,   0, 1, FALSE);

-- 5. Lotes (vencido, próximo a vencer, vigente lejano, sin vencimiento NULL y agotado)
INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en) VALUES
                                                               (1, 'LOT-VAC-EXP',  CURRENT_DATE - INTERVAL '5 days',   CURRENT_DATE - INTERVAL '60 days'), -- Vencido
                                                               (1, 'LOT-VAC-10D',  CURRENT_DATE + INTERVAL '10 days',  CURRENT_DATE - INTERVAL '20 days'), -- Próximo a vencer
                                                               (1, 'LOT-VAC-90D',  CURRENT_DATE + INTERVAL '90 days',  CURRENT_DATE - INTERVAL '5 days'),  -- Vigente normal
                                                               (2, 'LOT-SUE-15D',  CURRENT_DATE + INTERVAL '15 days',  CURRENT_DATE - INTERVAL '10 days'), -- Próximo a vencer
                                                               (3, 'LOT-GUA-NULL', NULL,                               CURRENT_DATE - INTERVAL '30 days'), -- Sin vencimiento
                                                               (4, 'LOT-JER-ZERO', CURRENT_DATE + INTERVAL '180 days', CURRENT_DATE - INTERVAL '40 days'); -- Quedará agotado

-- 6. Órdenes de Compra (una PARCIAL y una ABIERTA)
INSERT INTO orden_compra (supplier_id, estado) VALUES
                                                   (2, 'PARCIAL'), -- po_id = 1
                                                   (1, 'ABIERTA'); -- po_id = 2

INSERT INTO detalle_compra (po_id, line_no, sku_id, qty_ordered, costo_unitario) VALUES
                                                                                     (1, 1, 1, 100, 18.50), -- Se recibirán solo 60 (recepción parcial)
                                                                                     (1, 2, 2,  80,  3.20), -- Se recibirán los 80 completos
                                                                                     (2, 1, 3, 120,  6.75); -- Pendiente total (0 recibidos)

-- 7. Movimientos iniciales (El trigger actualiza existencia_lote automáticamente)
INSERT INTO movimiento (lot_id, origen_location_id, destino_location_id, tipo, cantidad, po_id, po_line_no, observacion) VALUES
                                                                                                                             (1, NULL, 1, 'RECEPCION', 15, NULL, NULL, 'Saldo inicial lote vencido'),
                                                                                                                             (2, NULL, 1, 'RECEPCION', 25, 1,    1,    'Recepción parcial OC-1 línea 1 (parte A)'),
                                                                                                                             (3, NULL, 2, 'RECEPCION', 35, 1,    1,    'Recepción parcial OC-1 línea 1 (parte B)'),
                                                                                                                             (4, NULL, 1, 'RECEPCION', 80, 1,    2,    'Recepción completa OC-1 línea 2'),
                                                                                                                             (5, NULL, 4, 'RECEPCION', 20, NULL, NULL, 'Stock inicial guantes sin caducidad (bajo mínimo)'),
                                                                                                                             (6, NULL, 4, 'RECEPCION', 10, NULL, NULL, 'Stock inicial jeringas');

-- Agotamos el lote 6 mediante un despacho directo para tener un lote en 0 unidades
INSERT INTO movimiento (lot_id, origen_location_id, destino_location_id, tipo, cantidad, observacion) VALUES
    (6, 4, NULL, 'DESPACHO', 10, 'Consumo total de lote 6 para prueba de lote agotado');

-- 8. Pedidos y Reservas FEFO vigentes
INSERT INTO pedido (estado) VALUES
                                ('RESERVADO'), -- order_id = 1
                                ('PARCIAL');   -- order_id = 2

INSERT INTO detalle_pedido (order_id, line_no, sku_id, qty_requested) VALUES
                                                                          (1, 1, 1, 30), -- Pide 30 de Reactivo: toma 25 del LOT-VAC-10D + 5 del LOT-VAC-90D
                                                                          (2, 1, 2, 50); -- Pide 50 de Suero (se atenderán 30 y quedarán 20 sin atender para quiebres)

-- Registramos las reservas y actualizamos qty_reserved en existencia_lote
INSERT INTO reserva (order_id, line_no, lot_id, location_id, qty_reserved, estado) VALUES
                                                                                       (1, 1, 2, 1, 25, 'ACTIVA'),
                                                                                       (1, 1, 3, 2,  5, 'ACTIVA'),
                                                                                       (2, 1, 4, 1, 30, 'ACTIVA');

UPDATE existencia_lote SET qty_reserved = 25 WHERE lot_id = 2 AND location_id = 1;
UPDATE existencia_lote SET qty_reserved =  5 WHERE lot_id = 3 AND location_id = 2;
UPDATE existencia_lote SET qty_reserved = 30 WHERE lot_id = 4 AND location_id = 1;

COMMIT;

-- ============================================================================
-- 9. PRUEBAS DE INTEGRIDAD (5 casos exigidos en la sección 3)
-- ============================================================================

DO $test$
    BEGIN
        -- PRUEBA 1: FK inválida (intentar reservar un lote inexistente)
        BEGIN
            INSERT INTO reserva (order_id, line_no, lot_id, location_id, qty_reserved)
            VALUES (1, 1, 9999, 1, 5);
            RAISE EXCEPTION 'FALLO PRUEBA 1: Se permitió FK inválida';
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE NOTICE 'OK PRUEBA 1 (FK inválida rechazada): %', SQLERRM;
        END;

        -- PRUEBA 2: Cantidad negativa / sobre-reserva (reservar más que qty_on_hand)
        BEGIN
            UPDATE existencia_lote SET qty_reserved = 999 WHERE lot_id = 2 AND location_id = 1;
            RAISE EXCEPTION 'FALLO PRUEBA 2: Se permitió qty_reserved > qty_on_hand';
        EXCEPTION WHEN check_violation THEN
            RAISE NOTICE 'OK PRUEBA 2 (Sobre-reserva / cantidad inválida rechazada): %', SQLERRM;
        END;

        -- PRUEBA 3: Clave duplicada (código de SKU repetido)
        BEGIN
            INSERT INTO producto (sku_code, nombre) VALUES ('SKU-VAC-01', 'Duplicado');
            RAISE EXCEPTION 'FALLO PRUEBA 3: Se permitió sku_code duplicado';
        EXCEPTION WHEN unique_violation THEN
            RAISE NOTICE 'OK PRUEBA 3 (Clave duplicada rechazada): %', SQLERRM;
        END;

        -- PRUEBA 4: Fecha inconsistente (vence_en anterior a recibido_en)
        BEGIN
            INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en)
            VALUES (1, 'LOT-BAD-DATE', '2026-01-01', '2026-06-01');
            RAISE EXCEPTION 'FALLO PRUEBA 4: Se permitió fecha de vencimiento < recepción';
        EXCEPTION WHEN check_violation THEN
            RAISE NOTICE 'OK PRUEBA 4 (Fecha inconsistente rechazada): %', SQLERRM;
        END;

        -- PRUEBA 5: Transición / mutación no permitida (intentar borrar movimiento histórico)
        BEGIN
            DELETE FROM movimiento WHERE movement_id = 1;
            RAISE EXCEPTION 'FALLO PRUEBA 5: Se permitió borrar movimiento';
        EXCEPTION WHEN raise_exception THEN
            RAISE NOTICE 'OK PRUEBA 5 (Inmutabilidad del kardex protegida): %', SQLERRM;
        END;
    END;
$test$;