-- ============================================================================
-- SMART INVENTORY - 04_transactions.sql
-- Reserva atómica FEFO con bloqueo pesimista (FOR UPDATE) y prueba concurrente
-- ============================================================================

-- 1. Procedimiento almacenado de Reserva FEFO Atómica
CREATE OR REPLACE PROCEDURE sp_reservar_fefo(
    p_order_id BIGINT,
    p_line_no  INTEGER
)
    LANGUAGE plpgsql
AS $proc$
DECLARE
    v_sku_id        BIGINT;
    v_qty_pedida    INTEGER;
    v_ya_reservado  INTEGER;
    v_restante      INTEGER;
    v_asignar       INTEGER;
    rec_lote        RECORD;
BEGIN
    SELECT sku_id, qty_requested
    INTO v_sku_id, v_qty_pedida
    FROM detalle_pedido
    WHERE order_id = p_order_id
      AND line_no = p_line_no;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Línea de pedido no existe (order_id=%, line_no=%)', p_order_id, p_line_no;
    END IF;

    SELECT COALESCE(SUM(qty_reserved), 0)
    INTO v_ya_reservado
    FROM reserva
    WHERE order_id = p_order_id
      AND line_no = p_line_no
      AND estado IN ('ACTIVA', 'CONSUMIDA');

    v_restante := v_qty_pedida - v_ya_reservado;

    IF v_restante <= 0 THEN
        RAISE NOTICE 'La línea ya se encuentra cubierta al 100%%.';
        RETURN;
    END IF;

    -- Bloquear existencias elegibles en orden FEFO + orden determinista de clave (evita deadlocks)
    FOR rec_lote IN
        SELECT
            el.lot_id,
            el.location_id,
            l.lot_code,
            l.vence_en,
            (el.qty_on_hand - el.qty_reserved) AS disponible
        FROM existencia_lote el
                 JOIN lote l ON l.lot_id = el.lot_id
        WHERE l.sku_id = v_sku_id
          AND (l.vence_en IS NULL OR l.vence_en > CURRENT_DATE)
          AND (el.qty_on_hand - el.qty_reserved) > 0
        ORDER BY
            l.vence_en ASC NULLS LAST,
            l.recibido_en ASC,
            el.lot_id ASC,
            el.location_id ASC
            FOR UPDATE OF el
        LOOP
            EXIT WHEN v_restante = 0;

            v_asignar := LEAST(rec_lote.disponible, v_restante);

            INSERT INTO reserva (order_id, line_no, lot_id, location_id, qty_reserved, estado)
            VALUES (p_order_id, p_line_no, rec_lote.lot_id, rec_lote.location_id, v_asignar, 'ACTIVA');

            UPDATE existencia_lote
            SET qty_reserved = qty_reserved + v_asignar
            WHERE lot_id = rec_lote.lot_id
              AND location_id = rec_lote.location_id;

            v_restante := v_restante - v_asignar;
        END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION 'Stock insuficiente para SKU % (order_id=%, line_no=%). Faltaron % unidades. Se revierte la transacción.',
            v_sku_id, p_order_id, p_line_no, v_restante;
    END IF;

    UPDATE pedido
    SET estado = 'RESERVADO'
    WHERE order_id = p_order_id;
END;
$proc$;

-- ============================================================================
-- 2. PREPARACIÓN IDEMPOTENTE DEL ESCENARIO DE CONCURRENCIA (SKU-CONC-99)
-- ============================================================================

DO $setup$
    DECLARE
        v_sku_id  BIGINT;
        v_lot_exp BIGINT;
        v_lot_a   BIGINT;
        v_lot_b   BIGINT;
    BEGIN
        SELECT sku_id INTO v_sku_id FROM producto WHERE sku_code = 'SKU-CONC-99';

        IF v_sku_id IS NULL THEN
            INSERT INTO producto (sku_code, nombre, unidad, stock_minimo, stock_objetivo, default_supplier_id)
            VALUES ('SKU-CONC-99', 'Ampolla Adrenalina 1mg (Test Concurrencia)', 'CAJA', 10, 50, 2)
            RETURNING sku_id INTO v_sku_id;

            INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en)
            VALUES (v_sku_id, 'LOT-CONC-EXP', CURRENT_DATE - INTERVAL '2 days', CURRENT_DATE - INTERVAL '30 days')
            RETURNING lot_id INTO v_lot_exp;

            INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en)
            VALUES (v_sku_id, 'LOT-CONC-A', CURRENT_DATE + INTERVAL '5 days', CURRENT_DATE - INTERVAL '15 days')
            RETURNING lot_id INTO v_lot_a;

            INSERT INTO lote (sku_id, lot_code, vence_en, recibido_en)
            VALUES (v_sku_id, 'LOT-CONC-B', CURRENT_DATE + INTERVAL '20 days', CURRENT_DATE - INTERVAL '10 days')
            RETURNING lot_id INTO v_lot_b;

            INSERT INTO movimiento (lot_id, destino_location_id, tipo, cantidad, observacion) VALUES
                                                                                                  (v_lot_exp, 1, 'RECEPCION', 50, 'Stock vencido test'),
                                                                                                  (v_lot_a,   1, 'RECEPCION',  6, 'Lote A test FEFO'),
                                                                                                  (v_lot_b,   1, 'RECEPCION',  6, 'Lote B test FEFO');
        END IF;
    END;
$setup$;

-- Crear 2 pedidos nuevos de 8 unidades cada uno (demanda total = 16 > 12 elegibles)
WITH nuevo_p1 AS (
    INSERT INTO pedido (estado) VALUES ('PENDIENTE') RETURNING order_id
),
     nuevo_p2 AS (
         INSERT INTO pedido (estado) VALUES ('PENDIENTE') RETURNING order_id
     ),
     sku AS (
         SELECT sku_id FROM producto WHERE sku_code = 'SKU-CONC-99'
     )
INSERT INTO detalle_pedido (order_id, line_no, sku_id, qty_requested)
SELECT order_id, 1, sku_id, 8 FROM nuevo_p1 CROSS JOIN sku
UNION ALL
SELECT order_id, 1, sku_id, 8 FROM nuevo_p2 CROSS JOIN sku;

-- Consultar los 2 order_id recién creados para usarlos en las dos consolas:
SELECT dp.order_id, dp.line_no, p.sku_code, dp.qty_requested, ped.estado
FROM detalle_pedido dp
         JOIN producto p ON p.sku_id = dp.sku_id
         JOIN pedido ped ON ped.order_id = dp.order_id
WHERE p.sku_code = 'SKU-CONC-99'
  AND ped.estado = 'PENDIENTE'
ORDER BY dp.order_id DESC
LIMIT 2;

-- ============================================================================
-- 3. GUÍA DE EJECUCIÓN EN DOS SESIONES CONCURRENTES (Consola 1 y Consola 2)
-- Reemplazar <ID_1> y <ID_2> por los order_id obtenidos arriba:
--
-- [CONSOLA 1 - Sesión A]:
--   BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
--   CALL sp_reservar_fefo(<ID_1>, 1);
--   -- (Dejar abierta sin COMMIT)
--
-- [CONSOLA 2 - Sesión B] (ejecutar mientras Consola 1 sigue abierta):
--   BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
--   CALL sp_reservar_fefo(<ID_2>, 1);
--   -- (Queda bloqueada esperando el lock FOR UPDATE de Sesión A)
--
-- [CONSOLA 1 - Sesión A]:
--   COMMIT;
--
-- [CONSOLA 2 - Sesión B]:
--   -- Se desbloquea y lanza ERROR [P0001]: Stock insuficiente... Faltaron 4 unidades.
--   ROLLBACK;
-- ============================================================================